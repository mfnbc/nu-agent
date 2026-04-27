use blake3::Hasher;
use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::LabeledError;
use nu_protocol::Value;
use nu_protocol::{IntoInterruptiblePipelineData, PipelineData, Signals, Signature, SyntaxShape, Type};
use reqwest::blocking::Client;
use serde_json::json;
use std::collections::VecDeque;

use crate::state::RagPlugin;

pub struct Embed;

impl Embed {
    pub fn deterministic_embedding(text: &str, dim: usize) -> Vec<f32> {
        let hash = blake3::hash(text.as_bytes());
        let bytes = hash.as_bytes();
        let mut out = Vec::with_capacity(dim);
        let mut i = 0u32;
        while out.len() < dim {
            let mut h = Hasher::new();
            h.update(bytes);
            h.update(&i.to_le_bytes());
            let r = h.finalize();
            for chunk in r.as_bytes().chunks(4) {
                if out.len() >= dim {
                    break;
                }
                let mut arr = [0u8; 4];
                for (j, b) in chunk.iter().enumerate() {
                    arr[j] = *b;
                }
                let u = u32::from_le_bytes(arr);
                let f = (u as f32 / std::u32::MAX as f32) * 2.0 - 1.0;
                out.push(f);
            }
            i += 1;
        }
        let norm: f32 = out.iter().map(|x| x * x).sum::<f32>().sqrt();
        if norm > 0.0 {
            out.iter_mut().for_each(|x| *x /= norm);
        }
        out
    }

    /// Send a batch of texts to the embedding HTTP API and parse embeddings.
    pub fn http_embed_texts(
        client: &reqwest::blocking::Client,
        url: &str,
        model: &str,
        texts: &[String],
    ) -> Result<Vec<Vec<f32>>, LabeledError> {
        let payload = json!({"model": model, "input": texts});
        match client.post(url).json(&payload).send() {
            Ok(resp) => match resp.json::<serde_json::Value>() {
                Ok(json_resp) => {
                    if let Some(arr) = json_resp.get("data").and_then(|d| d.as_array()) {
                        let mut out: Vec<Vec<f32>> = Vec::new();
                        for item in arr.iter() {
                            if let Some(emb_v) = item.get("embedding").and_then(|e| e.as_array()) {
                                let mut vec_f: Vec<f32> = Vec::with_capacity(emb_v.len());
                                for num in emb_v.iter() {
                                    if let Some(n) = num.as_f64() {
                                        vec_f.push(n as f32);
                                    }
                                }
                                out.push(vec_f);
                            }
                        }
                        Ok(out)
                    } else {
                        Err(LabeledError::new(
                            "missing data.embedding in response".to_string(),
                        ))
                    }
                }
                Err(e) => Err(LabeledError::new(format!(
                    "failed to parse json response: {}",
                    e
                ))),
            },
            Err(e) => Err(LabeledError::new(format!("http request failed: {}", e))),
        }
    }
}

impl PluginCommand for Embed {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag embed"
    }

    fn description(&self) -> &str {
        "Attach embeddings to incoming records (mock or live)."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .switch("mock", "Use deterministic mock embeddings", Some('m'))
            .named(
                "batch-size",
                SyntaxShape::Int,
                "Batch size for embedding requests",
                Some('b'),
            )
            .named("dim", SyntaxShape::Int, "Embedding dimension", Some('d'))
            .named(
                "column",
                SyntaxShape::String,
                "Record column to use as the text to embed (default: input)",
                Some('c'),
            )
            .named(
                "url",
                SyntaxShape::String,
                "Embedding API URL (default: http://172.19.224.1:1234/v1/embeddings)",
                Some('u'),
            )
            .named(
                "model",
                SyntaxShape::String,
                "Embedding model name (default: text-embedding-mxbai-embed-large-v1)",
                Some('o'),
            )
            .input_output_type(Type::Any, Type::Any)
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let span = call.head;

        // Read flags (map shell errors to LabeledError)
        let mock = call
            .has_flag("mock")
            .map_err(|e| LabeledError::new(format!("failed to read mock flag: {}", e)))?;
        let batch_size = call
            .get_flag::<i64>("batch-size")
            .map_err(|e| LabeledError::new(format!("failed to read batch-size: {}", e)))?
            .unwrap_or(16) as usize;
        let dim = call
            .get_flag::<i64>("dim")
            .map_err(|e| LabeledError::new(format!("failed to read dim: {}", e)))?
            .unwrap_or(768) as usize;
        let column = call
            .get_flag::<String>("column")
            .map_err(|e| LabeledError::new(format!("failed to read column flag: {}", e)))?
            .unwrap_or_else(|| "input".to_string());

        // Stream results as they are computed instead of collecting everything in memory.
        let column = column.clone();
        let span_for_values = span;

        // Prepare HTTP client and flags for live path
        let client = Client::new();
        let url = call
            .get_flag::<String>("url")
            .map_err(|e| LabeledError::new(format!("failed to read url flag: {}", e)))?
            .unwrap_or_else(|| "http://172.19.224.1:1234/v1/embeddings".to_string());
        let model = call
            .get_flag::<String>("model")
            .map_err(|e| LabeledError::new(format!("failed to read model flag: {}", e)))?
            .unwrap_or_else(|| "text-embedding-mxbai-embed-large-v1".to_string());

        let mut input_iter = input.into_iter();
        let mut pending: VecDeque<Value> = VecDeque::new();

        let iter = std::iter::from_fn(move || {
            // If we have pending results from the last batch, yield them first
            if let Some(v) = pending.pop_front() {
                return Some(v);
            }

            // Collect the next batch
            let mut batch: Vec<Value> = Vec::with_capacity(batch_size);
            for _ in 0..batch_size {
                match input_iter.next() {
                    Some(v) => batch.push(v),
                    None => break,
                }
            }

            if batch.is_empty() {
                return None;
            }

            // Extract texts for the batch
            let texts: Vec<String> = batch
                .iter()
                .map(|v| match v {
                    Value::Record { val, .. } => {
                        let rec = &**val;
                        match rec.get(&column) {
                            Some(value) => value
                                .coerce_string()
                                .unwrap_or_else(|_| format!("{:?}", value)),
                            None => format!("{:?}", v),
                        }
                    }
                    Value::String { val, .. } => val.clone(),
                    other => other
                        .coerce_string()
                        .unwrap_or_else(|_| format!("{:?}", other)),
                })
                .collect();

            // Obtain embeddings either via mock or HTTP
            let embeddings_result: Result<Vec<Vec<f32>>, LabeledError> = if mock {
                Ok(texts
                    .iter()
                    .map(|t| Embed::deterministic_embedding(t, dim))
                    .collect())
            } else {
                // Build payload
                let payload = json!({"model": model, "input": texts});
                // Send HTTP request (blocking)
                match client.post(&url).json(&payload).send() {
                    Ok(resp) => match resp.json::<serde_json::Value>() {
                        Ok(json_resp) => {
                            // Try extract embeddings from json_resp.data[*].embedding
                            if let Some(arr) = json_resp.get("data").and_then(|d| d.as_array()) {
                                let mut out: Vec<Vec<f32>> = Vec::new();
                                for item in arr.iter() {
                                    if let Some(emb_v) =
                                        item.get("embedding").and_then(|e| e.as_array())
                                    {
                                        let mut vec_f: Vec<f32> = Vec::with_capacity(emb_v.len());
                                        for num in emb_v.iter() {
                                            if let Some(n) = num.as_f64() {
                                                vec_f.push(n as f32);
                                            }
                                        }
                                        out.push(vec_f);
                                    }
                                }
                                Ok(out)
                            } else {
                                Err(LabeledError::new(
                                    "missing data.embedding in response".to_string(),
                                ))
                            }
                        }
                        Err(e) => Err(LabeledError::new(format!(
                            "failed to parse json response: {}",
                            e
                        ))),
                    },
                    Err(e) => Err(LabeledError::new(format!("http request failed: {}", e))),
                }
            };

            match embeddings_result {
                Ok(embeddings) => {
                    // Zip embeddings back onto original records and push into pending queue
                    for (orig, emb) in batch.into_iter().zip(embeddings.into_iter()) {
                        let list_values: Vec<Value> = emb
                            .into_iter()
                            .map(|f| Value::float(f as f64, span_for_values))
                            .collect();
                        let rec_val = match orig {
                            Value::Record { val, .. } => {
                                let mut rec = (*val).clone();
                                rec.insert(
                                    "embedding",
                                    Value::list(list_values, span_for_values),
                                );
                                Value::record(rec, span_for_values)
                            }
                            other => {
                                let mut rec = nu_protocol::Record::new();
                                rec.push("value".to_string(), other);
                                rec.push(
                                    "embedding".to_string(),
                                    Value::list(list_values, span_for_values),
                                );
                                Value::record(rec, span_for_values)
                            }
                        };
                        pending.push_back(rec_val);
                    }
                }
                Err(err) => {
                    // For failures, report an error on each record but continue streaming the rest.
                    for orig in batch.into_iter() {
                        // Create a Value::Error containing the message, but keep original record
                        let msg = format!("embedding request failed: {}", err);
                        let error_val = Value::error(
                            nu_protocol::ShellError::GenericError {
                                error: msg.clone(),
                                msg: msg.clone(),
                                span: Some(span_for_values),
                                help: None,
                                inner: vec![],
                            },
                            span_for_values,
                        );

                        let rec_val = match orig {
                            Value::Record { val, .. } => {
                                let mut rec = (*val).clone();
                                // attach the error as the embedding field
                                rec.insert("embedding", error_val.clone());
                                Value::record(rec, span_for_values)
                            }
                            other => {
                                let mut rec = nu_protocol::Record::new();
                                rec.push("value".to_string(), other);
                                rec.push("embedding".to_string(), error_val.clone());
                                Value::record(rec, span_for_values)
                            }
                        };
                        pending.push_back(rec_val);
                    }
                }
            }

            // Return first result
            pending.pop_front()
        });

        Ok(iter.into_pipeline_data(call.head, Signals::empty()))
    }
}
