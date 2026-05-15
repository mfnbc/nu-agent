use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{IntoInterruptiblePipelineData, LabeledError, PipelineData, Signals, Signature, SyntaxShape, Type, Value, IntoPipelineData};
use serde_json::Value as JsonValue;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use rayon::prelude::*;

use crate::state::RagPlugin;
use crate::commands::similarity::Similarity;

pub struct AnnBuild;
pub struct AnnQuery;

impl PluginCommand for AnnBuild {
    type Plugin = RagPlugin;

    fn name(&self) -> &str { "rag ann-build" }

    fn description(&self) -> &str { "Build a simple vector index (exact, persisted) from NDJSON embeddings" }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named("input", SyntaxShape::String, "NDJSON input file with records containing id and embedding", Some('i'))
            .named("id-field", SyntaxShape::String, "JSON field for id (default: xxh3_hash)", Some('d'))
            .named("emb-field", SyntaxShape::String, "JSON field for embedding (default: embedding)", Some('e'))
            .named("out-index", SyntaxShape::String, "Output index file path", Some('o'))
            .named("out-map", SyntaxShape::String, "Output id map JSON path", Some('m'))
            .input_output_type(Type::Any, Type::String)
    }

    fn run(&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData) -> Result<PipelineData, LabeledError> {
        let input = call.get_flag::<String>("input").map_err(|e| LabeledError::new(format!("--input: {}", e)))?.ok_or_else(|| LabeledError::new("--input required"))?;
        let id_field = call.get_flag::<String>("id-field").map_err(|e| LabeledError::new(format!("--id-field: {}", e)))?.unwrap_or_else(|| "xxh3_hash".to_string());
        let emb_field = call.get_flag::<String>("emb-field").map_err(|e| LabeledError::new(format!("--emb-field: {}", e)))?.unwrap_or_else(|| "embedding".to_string());
        let out_index = call.get_flag::<String>("out-index").map_err(|e| LabeledError::new(format!("--out-index: {}", e)))?.unwrap_or_else(|| "data/ann/index.bin".to_string());
        let out_map = call.get_flag::<String>("out-map").map_err(|e| LabeledError::new(format!("--out-map: {}", e)))?.unwrap_or_else(|| "data/ann/index_map.json".to_string());

        let file = File::open(&input).map_err(|e| LabeledError::new(format!("Failed to open input file: {}", e)))?;
        let reader = BufReader::new(file);

        let mut ids: Vec<String> = Vec::new();
        let mut vecs: Vec<Vec<f32>> = Vec::new();
        let mut dim: Option<usize> = None;

        for line in reader.lines() {
            let l = line.map_err(|e| LabeledError::new(format!("IO error reading input: {}", e)))?;
            let s = l.trim();
            if s.is_empty() { continue; }
            let j: JsonValue = serde_json::from_str(s).map_err(|e| LabeledError::new(format!("Failed to parse JSON line: {}", e)))?;
            // extract id
            let id_val = j.get(&id_field).ok_or_else(|| LabeledError::new(format!("Missing id field '{}' in record", id_field)))?;
            let id = if id_val.is_string() { id_val.as_str().unwrap().to_string() } else { id_val.to_string() };

            let emb_val = j.get(&emb_field).ok_or_else(|| LabeledError::new(format!("Missing embedding field '{}' in record", emb_field)))?;
            // convert embedding JsonValue to Vec<f32>
            let emb = match emb_val {
                JsonValue::Array(arr) => {
                    let mut v = Vec::with_capacity(arr.len());
                    for a in arr.iter() {
                        match a {
                            JsonValue::Number(n) => {
                                if let Some(f) = n.as_f64() { v.push(f as f32); }
                                else { return Err(LabeledError::new("Embedding number parse error")); }
                            }
                            _ => return Err(LabeledError::new("Embedding array contains non-number")),
                        }
                    }
                    v
                }
                _ => return Err(LabeledError::new("Embedding field is not an array")),
            };

            if let Some(d) = dim { if d != emb.len() { return Err(LabeledError::new("Inconsistent embedding dimension")); } }
            else { dim = Some(emb.len()); }

            ids.push(id);
            vecs.push(emb);
        }

        let dim = dim.ok_or_else(|| LabeledError::new("No embeddings found in input"))?;
        let count = vecs.len();

        // Ensure parent dir exists
        if let Some(p) = Path::new(&out_index).parent() { std::fs::create_dir_all(p).map_err(|e| LabeledError::new(format!("Failed to create output dir: {}", e)))?; }
        if let Some(p) = Path::new(&out_map).parent() { std::fs::create_dir_all(p).map_err(|e| LabeledError::new(format!("Failed to create output dir: {}", e)))?; }

        // write binary index: [u64 count][u64 dim][f32*count*dim]
        let mut f = File::create(&out_index).map_err(|e| LabeledError::new(format!("Failed to create index file: {}", e)))?;
        f.write_all(&(count as u64).to_le_bytes()).map_err(|e| LabeledError::new(format!("Failed to write index file: {}", e)))?;
        f.write_all(&(dim as u64).to_le_bytes()).map_err(|e| LabeledError::new(format!("Failed to write index file: {}", e)))?;
        for row in vecs.iter() {
            for &x in row.iter() {
                f.write_all(&x.to_le_bytes()).map_err(|e| LabeledError::new(format!("Failed to write vector data: {}", e)))?;
            }
        }
        f.sync_all().map_err(|e| LabeledError::new(format!("Failed to sync index file: {}", e)))?;

        // write map
        let map_f = File::create(&out_map).map_err(|e| LabeledError::new(format!("Failed to create map file: {}", e)))?;
        serde_json::to_writer_pretty(map_f, &ids).map_err(|e| LabeledError::new(format!("Failed to write map file: {}", e)))?;

        Ok(Value::string(format!("Wrote index with {} vectors (dim={}) to {}", count, dim, out_index), call.head).into_pipeline_data())
    }
}

impl PluginCommand for AnnQuery {
    type Plugin = RagPlugin;

    fn name(&self) -> &str { "rag ann-query" }

    fn description(&self) -> &str { "Query a persisted vector index with a query vector (exact search)." }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named("index", SyntaxShape::String, "Index file path", Some('i'))
            .named("map", SyntaxShape::String, "Index map JSON path", Some('m'))
            .named("query", SyntaxShape::List(Box::new(SyntaxShape::Number)), "Query embedding vector", Some('q'))
            .named("k", SyntaxShape::Int, "Top-k results (default 5)", Some('k'))
            .input_output_type(Type::Any, Type::Any)
    }

    fn run(&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData) -> Result<PipelineData, LabeledError> {
        let index_path = call.get_flag::<String>("index").map_err(|e| LabeledError::new(format!("--index: {}", e)))?.ok_or_else(|| LabeledError::new("--index required"))?;
        let map_path = call.get_flag::<String>("map").map_err(|e| LabeledError::new(format!("--map: {}", e)))?.ok_or_else(|| LabeledError::new("--map required"))?;
        let query_value = call.get_flag::<Value>("query").map_err(|e| LabeledError::new(format!("--query: {}", e)))?.ok_or_else(|| LabeledError::new("--query required"))?;
        let k = call.get_flag::<i64>("k").map_err(|e| LabeledError::new(format!("--k: {}", e)))?.map(|v| v as usize).unwrap_or(5);

        // extract query vector
        let query_vec = Similarity::extract_vec(&query_value).ok_or_else(|| LabeledError::new("--query must be a list of numbers"))?;

        // load map
        let map_file = File::open(&map_path).map_err(|e| LabeledError::new(format!("Failed to open map file: {}", e)))?;
        let ids: Vec<String> = serde_json::from_reader(map_file).map_err(|e| LabeledError::new(format!("Failed to parse map file: {}", e)))?;

        // load index binary
        let mut f = File::open(&index_path).map_err(|e| LabeledError::new(format!("Failed to open index file: {}", e)))?;
        use std::io::Read;
        let mut buf8 = [0u8;8];
        f.read_exact(&mut buf8).map_err(|e| LabeledError::new(format!("Failed to read index header: {}", e)))?;
        let count = u64::from_le_bytes(buf8) as usize;
        f.read_exact(&mut buf8).map_err(|e| LabeledError::new(format!("Failed to read index header: {}", e)))?;
        let dim = u64::from_le_bytes(buf8) as usize;

        if ids.len() != count { return Err(LabeledError::new("Index count and map length mismatch")); }
        if query_vec.len() != dim { return Err(LabeledError::new("Query dimension does not match index")); }

        // read all vector data
        let mut data: Vec<f32> = Vec::with_capacity(count * dim);
        let mut buf4 = [0u8;4];
        for _ in 0..(count*dim) {
            f.read_exact(&mut buf4).map_err(|e| LabeledError::new(format!("Failed to read vector data: {}", e)))?;
            data.push(f32::from_le_bytes(buf4));
        }

        // compute scores in parallel
        let dim_local = dim;
        let q = query_vec;
        let mut scores: Vec<(f32, usize)> = (0..count).into_par_iter().map(|i| {
            let start = i * dim_local;
            let slice = &data[start..start+dim_local];
            let s = Similarity::cosine(&q, slice);
            (s, i)
        }).collect();

        // sort descending and take top-k
        scores.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let results: Vec<(f32, usize)> = scores.into_iter().take(k).collect();

        let mut out: Vec<Value> = Vec::new();
        for (s, idx) in results {
            let mut rec = nu_protocol::Record::new();
            rec.push("id".to_string(), Value::string(ids[idx].clone(), call.head));
            rec.push("index".to_string(), Value::int(idx as i64, call.head));
            rec.push("score".to_string(), Value::float(s as f64, call.head));
            out.push(Value::record(rec, call.head));
        }

        Ok(out.into_pipeline_data(call.head, Signals::empty()))
    }
}
