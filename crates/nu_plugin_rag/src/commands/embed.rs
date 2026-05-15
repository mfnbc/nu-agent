use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{IntoInterruptiblePipelineData, LabeledError, PipelineData, Signals, Signature, SyntaxShape, Type, Value, IntoPipelineData};
use blake3;
use std::io::Write;
use std::fs::File;
use serde_json::json;

use crate::state::RagPlugin;

pub struct Embed;

impl Embed {
    fn text_to_embedding(text: &str, dim: usize) -> Vec<f32> {
        // Deterministic mock embedding using blake3 stream; expand bytes to f32 in [-1,1]
        let mut out = Vec::with_capacity(dim);
        let hash = blake3::hash(text.as_bytes()).as_bytes().to_vec();
        // expand by hashing hashes if needed
        let mut acc = hash.clone();
        while acc.len() < dim * 4 {
            let h = blake3::hash(&acc).as_bytes().to_vec();
            acc.extend_from_slice(&h);
        }
        for i in 0..dim {
            let base = i * 4;
            let bytes = &acc[base..base+4];
            let u = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let f = (u as f32) / (u32::MAX as f32);
            // shift to [-0.5,0.5]
            out.push(f - 0.5);
        }
        // normalize
        let mut norm = 0.0f32;
        for v in out.iter() { norm += v*v; }
        norm = norm.sqrt();
        if norm > 0.0 {
            for v in out.iter_mut() { *v /= norm; }
        }
        out
    }
}

impl PluginCommand for Embed {
    type Plugin = RagPlugin;

    fn name(&self) -> &str { "rag embed" }

    fn description(&self) -> &str { "Embed records' text field into an `embedding` field." }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named("field", SyntaxShape::String, "Text field to embed (default: text)", Some('f'))
            .named("out", SyntaxShape::String, "Optional output NDJSON path to write embeddings", Some('o'))
            .named("dim", SyntaxShape::Int, "Embedding dimension (mock only)", Some('d'))
            .named("url", SyntaxShape::String, "Embedding endpoint URL (OpenAI-compatible)", None)
            .named("model", SyntaxShape::String, "Embedding model name", None)
            .named("batch-size", SyntaxShape::Int, "Batch size for embeddings (default 64)", None)
            .switch("mock", "Use deterministic mock embeddings", None)
            .input_output_type(Type::Any, Type::Any)
    }

    fn run(&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, input: PipelineData) -> Result<PipelineData, LabeledError> {
        let field = call.get_flag::<String>("field").map_err(|e| LabeledError::new(format!("--field: {}", e)))?.unwrap_or_else(|| "text".to_string());
        let out_path = call.get_flag::<String>("out").map_err(|e| LabeledError::new(format!("--out: {}", e)))?;
        let dim = call.get_flag::<i64>("dim").map_err(|e| LabeledError::new(format!("--dim: {}", e)))?.map(|v| v as usize).unwrap_or(128);
        let mock = call.has_flag("mock").map_err(|e| LabeledError::new(format!("--mock: {}", e)))?;
        let batch_size = call.get_flag::<i64>("batch-size").map_err(|e| LabeledError::new(format!("--batch-size: {}", e)))?.map(|v| v as usize).unwrap_or(64);

        // URL & model fall back to environment var NU_AGENT_EMBEDDING_URL / NU_AGENT_EMBEDDING_MODEL when not provided
        let url_flag = call.get_flag::<String>("url").map_err(|e| LabeledError::new(format!("--url: {}", e)))?;
        let model_flag = call.get_flag::<String>("model").map_err(|e| LabeledError::new(format!("--model: {}", e)))?;
        let url = url_flag.or_else(|| std::env::var("NU_AGENT_EMBEDDING_URL").ok());
        let model = model_flag.or_else(|| std::env::var("NU_AGENT_EMBEDDING_MODEL").ok());

        // Collect input records
        let mut records: Vec<Value> = Vec::new();
        for v in input.into_iter() {
            records.push(v);
        }

        // Extract texts
        let mut texts: Vec<String> = Vec::with_capacity(records.len());
        for v in records.iter() {
            let text_val = match &v {
                Value::Record { val, .. } => val.get(&field).cloned(),
                _ => None,
            };
            let text = match text_val {
                Some(Value::String { val, .. }) => val,
                Some(other) => other.into_string().unwrap_or_default(),
                None => "".to_string(),
            };
            texts.push(text);
        }

        // If mock, compute deterministic embeddings locally
        let mut out_records: Vec<Value> = Vec::with_capacity(records.len());
        if mock {
            for (i, v) in records.into_iter().enumerate() {
                let emb = Embed::text_to_embedding(&texts[i], dim);
                let list = emb.iter().map(|&f| Value::float(f as f64, call.head)).collect::<Vec<_>>();
                let new_v = match v {
                    Value::Record { val, .. } => {
                        let mut rec = (*val).clone();
                        rec.push("embedding".to_string(), Value::list(list.clone(), call.head));
                        Value::record(rec, call.head)
                    }
                    other => {
                        let mut rec = nu_protocol::Record::new();
                        rec.push("text".to_string(), other);
                        rec.push("embedding".to_string(), Value::list(list.clone(), call.head));
                        Value::record(rec, call.head)
                    }
                };
                out_records.push(new_v);
            }
        } else {
            // Production path: require url & model
            let url = match url { Some(u) => u, None => return Err(LabeledError::new("No embedding URL provided; set --url or NU_AGENT_EMBEDDING_URL")) };
            let model = match model { Some(m) => m, None => return Err(LabeledError::new("No embedding model provided; set --model or NU_AGENT_EMBEDDING_MODEL")) };

            let client = reqwest::blocking::Client::new();
            let mut i = 0usize;
            while i < texts.len() {
                let end = usize::min(i + batch_size, texts.len());
                let batch = &texts[i..end];
                let body = serde_json::json!({ "model": model, "input": batch });
                let resp = client.post(&url).json(&body).send().map_err(|e| LabeledError::new(format!("Embedding request failed: {}", e)))?;
                if !resp.status().is_success() {
                    return Err(LabeledError::new(format!("Embedding endpoint returned error: {}", resp.status())));
                }
                let j: serde_json::Value = resp.json().map_err(|e| LabeledError::new(format!("Failed to parse embedding response: {}", e)))?;
                // Expect j.data is array of { embedding: [...] }
                let arr = j.get("data").and_then(|d| d.as_array()).ok_or_else(|| LabeledError::new("Embedding response missing data field"))?;
                if arr.len() != batch.len() {
                    return Err(LabeledError::new("Embedding response size mismatch"));
                }
                for (bi, rec_idx) in (i..end).enumerate() {
                    let emb_val = arr[bi].get("embedding").and_then(|e| e.as_array()).ok_or_else(|| LabeledError::new("Embedding element missing"))?;
                    let mut list = Vec::with_capacity(emb_val.len());
                    for n in emb_val.iter() {
                        if let Some(f) = n.as_f64() { list.push(Value::float(f, call.head)); }
                        else if let Some(i64v) = n.as_i64() { list.push(Value::int(i64v, call.head)); }
                        else { return Err(LabeledError::new("Embedding contains non-numeric")); }
                    }
                    let v = records[rec_idx].clone();
                    let new_v = match v {
                        Value::Record { val, .. } => {
                            let mut rec = (*val).clone();
                            rec.push("embedding".to_string(), Value::list(list.clone(), call.head));
                            Value::record(rec, call.head)
                        }
                        other => {
                            let mut rec = nu_protocol::Record::new();
                            rec.push("text".to_string(), other);
                            rec.push("embedding".to_string(), Value::list(list.clone(), call.head));
                            Value::record(rec, call.head)
                        }
                    };
                    out_records.push(new_v);
                }

                i = end;
            }
        }

        // If out_path provided, write NDJSON with minimal fields (xxh3_hash if present, embedding)
        if let Some(outp) = out_path {
            let mut f = File::create(outp).map_err(|e| LabeledError::new(format!("Failed to create out file: {}", e)))?;
            for v in out_records.iter() {
                if let Value::Record { val, .. } = v {
                    // try to extract xxh3_hash and embedding
                    let id = val.get("xxh3_hash").and_then(|x| x.clone().into_string().ok()).unwrap_or_default();
                    let emb_val = val.get("embedding").cloned();
                    if let Some(Value::List { vals, .. }) = emb_val {
                        let arr: Vec<f32> = vals.iter().filter_map(|vv| match vv { Value::Float{ val, .. } => Some(*val as f32), Value::Int{ val, .. } => Some(*val as f32), _ => None }).collect();
                        let j = serde_json::json!({ "xxh3_hash": id, "embedding": arr });
                        writeln!(f, "{}", j.to_string()).map_err(|e| LabeledError::new(format!("Failed write out file: {}", e)))?;
                    }
                }
            }
        }

        Ok(out_records.into_pipeline_data(call.head, Signals::empty()))
    }
}
