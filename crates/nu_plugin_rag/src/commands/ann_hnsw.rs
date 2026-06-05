use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{LabeledError, PipelineData, Signature, SyntaxShape, Type, Value, IntoInterruptiblePipelineData, IntoPipelineData, Signals};
use hnsw_rs::api::AnnT;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use serde_json::Value as JsonValue;
use std::path::Path;
use serde::{Serialize, Deserialize};

use crate::state::RagPlugin;
use crate::commands::similarity::Similarity;

// Lightweight wrapper types to persist id map and index data via serde_cbor
#[derive(Serialize, Deserialize)]
struct IdMap { ids: Vec<String> }

pub struct AnnHnswBuild;
pub struct AnnHnswQuery;

impl PluginCommand for AnnHnswBuild {
    type Plugin = RagPlugin;

    fn name(&self) -> &str { "rag ann-build-hnsw" }

    fn description(&self) -> &str { "Build an HNSW index (research prototype) from embeddings. Accepts NDJSON, Nuon/JSON-array, or MessagePack (msgpack) input." }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named("input", SyntaxShape::String, "Input file with records containing id and embedding (ndjson | nuon/json-array | msgpack)", Some('i'))
            .named("format", SyntaxShape::String, "Input format: ndjson|nuon|msgpack (autodetect by extension if omitted)", None)
            .named("id-field", SyntaxShape::String, "JSON field for id (default: xxh3_hash)", Some('d'))
            .named("emb-field", SyntaxShape::String, "JSON field for embedding (default: embedding)", Some('e'))
            .named("out-index", SyntaxShape::String, "Output index file path", Some('o'))
            .named("out-map", SyntaxShape::String, "Output id map JSON path", Some('m'))
            .named("m", SyntaxShape::Int, "HNSW m parameter (default 16)", None)
            .named("ef-construction", SyntaxShape::Int, "ef_construction (default 200)", None)
            .input_output_type(Type::Any, Type::String)
    }

    fn run(&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData) -> Result<PipelineData, LabeledError> {
        // Parse flags
        let input = call.get_flag::<String>("input").map_err(|e| LabeledError::new(format!("--input: {}", e)))?.ok_or_else(|| LabeledError::new("--input required"))?;
        let id_field = call.get_flag::<String>("id-field").map_err(|e| LabeledError::new(format!("--id-field: {}", e)))?.unwrap_or_else(|| "xxh3_hash".to_string());
        let emb_field = call.get_flag::<String>("emb-field").map_err(|e| LabeledError::new(format!("--emb-field: {}", e)))?.unwrap_or_else(|| "embedding".to_string());
        let out_index = call.get_flag::<String>("out-index").map_err(|e| LabeledError::new(format!("--out-index: {}", e)))?.unwrap_or_else(|| "data/ann/hnsw_index.cbor".to_string());
        let out_map = call.get_flag::<String>("out-map").map_err(|e| LabeledError::new(format!("--out-map: {}", e)))?.unwrap_or_else(|| "data/ann/hnsw_map.json".to_string());
        let m = call.get_flag::<i64>("m").map_err(|e| LabeledError::new(format!("--m: {}", e)))?.map(|v| v as usize).unwrap_or(16);
        let ef_c = call.get_flag::<i64>("ef-construction").map_err(|e| LabeledError::new(format!("--ef-construction: {}", e)))?.map(|v| v as usize).unwrap_or(200);

        // Read embeddings from input, supporting multiple formats (msgpack, nuon/json-array, ndjson)
        let fmt_flag = call.get_flag::<String>("format").map_err(|e| LabeledError::new(format!("--format: {}", e)))?.unwrap_or_default();
        let path = Path::new(&input);
        let mut ids: Vec<String> = Vec::new();
        let mut vecs: Vec<Vec<f32>> = Vec::new();
        let mut dim: Option<usize> = None;

        let effective_fmt = if fmt_flag != "" {
            fmt_flag.to_lowercase()
        } else if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
            ext.to_lowercase()
        } else { "ndjson".to_string() };

        if effective_fmt.contains("msg") || effective_fmt == "mpack" || effective_fmt == "msgpack" {
            // MessagePack: read entire file and deserialize to Vec<JsonValue>
            let f = File::open(&input).map_err(|e| LabeledError::new(format!("Failed to open input file: {}", e)))?;
            let v: Vec<JsonValue> = rmp_serde::from_read(f).map_err(|e| LabeledError::new(format!("Failed to parse msgpack input: {}", e)))?;
            for j in v.iter() {
                let id_val = j.get(&id_field).ok_or_else(|| LabeledError::new(format!("Missing id field '{}' in record", id_field)))?;
                let id = if id_val.is_string() { id_val.as_str().unwrap().to_string() } else { id_val.to_string() };
                let emb_val = j.get(&emb_field).ok_or_else(|| LabeledError::new(format!("Missing embedding field '{}' in record", emb_field)))?;
                let emb = match emb_val {
                    JsonValue::Array(arr) => {
                        let mut v = Vec::with_capacity(arr.len());
                        for a in arr.iter() {
                            match a {
                                JsonValue::Number(n) => { if let Some(f) = n.as_f64() { v.push(f as f32); } else { return Err(LabeledError::new("Embedding number parse error")); } }
                                _ => return Err(LabeledError::new("Embedding array contains non-number")),
                            }
                        }
                        v
                    }
                    _ => return Err(LabeledError::new("Embedding field is not an array")),
                };
                if let Some(d) = dim { if d != emb.len() { return Err(LabeledError::new("Inconsistent embedding dimension")); } } else { dim = Some(emb.len()); }
                // normalize
                let mut norm = 0.0f32; for &x in emb.iter() { norm += x*x; };
                let mut emb_norm = emb.clone();
                if norm > 0.0 { norm = norm.sqrt(); for v in emb_norm.iter_mut() { *v /= norm; } }
                ids.push(id);
                vecs.push(emb_norm);
            }
        } else {
            // Try reading entire file as a JSON array (nuon that is JSON-like), else fallback to NDJSON per-line
            let s = std::fs::read_to_string(&input).map_err(|e| LabeledError::new(format!("Failed to open input file: {}", e)))?;
            if let Ok(arr) = serde_json::from_str::<Vec<JsonValue>>(&s) {
                for j in arr.iter() {
                    let id_val = j.get(&id_field).ok_or_else(|| LabeledError::new(format!("Missing id field '{}' in record", id_field)))?;
                    let id = if id_val.is_string() { id_val.as_str().unwrap().to_string() } else { id_val.to_string() };
                    let emb_val = j.get(&emb_field).ok_or_else(|| LabeledError::new(format!("Missing embedding field '{}' in record", emb_field)))?;
                    let emb = match emb_val {
                        JsonValue::Array(arr) => {
                            let mut v = Vec::with_capacity(arr.len());
                            for a in arr.iter() {
                                match a {
                                    JsonValue::Number(n) => { if let Some(f) = n.as_f64() { v.push(f as f32); } else { return Err(LabeledError::new("Embedding number parse error")); } }
                                    _ => return Err(LabeledError::new("Embedding array contains non-number")),
                                }
                            }
                            v
                        }
                        _ => return Err(LabeledError::new("Embedding field is not an array")),
                    };
                    if let Some(d) = dim { if d != emb.len() { return Err(LabeledError::new("Inconsistent embedding dimension")); } } else { dim = Some(emb.len()); }
                    let mut norm = 0.0f32; for &x in emb.iter() { norm += x*x; };
                    let mut emb_norm = emb.clone();
                    if norm > 0.0 { norm = norm.sqrt(); for v in emb_norm.iter_mut() { *v /= norm; } }
                    ids.push(id);
                    vecs.push(emb_norm);
                }
            } else {
                // Fallback: NDJSON per-line (legacy behavior)
                let f = File::open(&input).map_err(|e| LabeledError::new(format!("Failed to open input file: {}", e)))?;
                let reader = BufReader::new(f);
                for line in reader.lines() {
                    let l = line.map_err(|e| LabeledError::new(format!("IO error reading input: {}", e)))?;
                    let s = l.trim();
                    if s.is_empty() { continue; }
                    let j: JsonValue = serde_json::from_str(s).map_err(|e| LabeledError::new(format!("Failed to parse JSON line: {}", e)))?;
                    let id_val = j.get(&id_field).ok_or_else(|| LabeledError::new(format!("Missing id field '{}' in record", id_field)))?;
                    let id = if id_val.is_string() { id_val.as_str().unwrap().to_string() } else { id_val.to_string() };
                    let emb_val = j.get(&emb_field).ok_or_else(|| LabeledError::new(format!("Missing embedding field '{}' in record", emb_field)))?;
                    let emb = match emb_val {
                        JsonValue::Array(arr) => {
                            let mut v = Vec::with_capacity(arr.len());
                            for a in arr.iter() {
                                match a {
                                    JsonValue::Number(n) => { if let Some(f) = n.as_f64() { v.push(f as f32); } else { return Err(LabeledError::new("Embedding number parse error")); } }
                                    _ => return Err(LabeledError::new("Embedding array contains non-number")),
                                }
                            }
                            v
                        }
                        _ => return Err(LabeledError::new("Embedding field is not an array")),
                    };
                    if let Some(d) = dim { if d != emb.len() { return Err(LabeledError::new("Inconsistent embedding dimension")); } } else { dim = Some(emb.len()); }
                    // normalize vector to unit length for cosine semantics
                    let mut norm = 0.0f32; for &x in emb.iter() { norm += x*x; };
                    let mut emb_norm = emb.clone();
                    if norm > 0.0 { norm = norm.sqrt(); for v in emb_norm.iter_mut() { *v /= norm; } }
                    ids.push(id);
                    vecs.push(emb_norm);
                }
            }
        }

        let dim = dim.ok_or_else(|| LabeledError::new("No embeddings found in input"))?;
        let count = vecs.len();

        // Build HNSW index using hnsw_rs (0.3.x API)
        use anndists::dist::distances::DistCosine;
        use hnsw_rs::hnsw::Hnsw;
        use hnsw_rs::hnswio::HnswIo;

        let max_layer = 16usize; // research default
        let ef_construct = ef_c;

        // create HNSW with DistCosine distance
        let mut hnsw = Hnsw::<f32, DistCosine>::new(m as usize, count, max_layer, ef_construct as usize, DistCosine {});

        // prepare slices for parallel insertion
        let mut slices: Vec<(&[f32], usize)> = vecs.iter().enumerate().map(|(i, v)| (v.as_slice(), i)).collect();

        // insert in parallel
        hnsw.parallel_insert_slice(&slices);

        // ensure output dir exists
        let out_index_path = Path::new(&out_index);
        if let Some(p) = out_index_path.parent() { std::fs::create_dir_all(p).map_err(|e| LabeledError::new(format!("Failed to create out dir: {}", e)))?; }
        if let Some(p) = Path::new(&out_map).parent() { std::fs::create_dir_all(p).map_err(|e| LabeledError::new(format!("Failed to create out dir: {}", e)))?; }

        // dump to HNSW files (graph + data) via file_dump
        let dir = out_index_path.parent().unwrap_or(Path::new("."));
        let basename = out_index_path.file_stem().and_then(|s| s.to_str()).unwrap_or("hnsw_index");
        let _dump_res = hnsw.file_dump(dir, basename).map_err(|e| LabeledError::new(format!("Failed to dump HNSW index: {}", e)))?;

        // write id map (JSON)
        let map_file = File::create(&out_map).map_err(|e| LabeledError::new(format!("Failed to create map file: {}", e)))?;
        serde_json::to_writer_pretty(map_file, &ids).map_err(|e| LabeledError::new(format!("Failed to write id map: {}", e)))?;

        Ok(Value::string(format!("Built HNSW index (n={} dim={}) -> {}.hnsw.{{graph,data}}", count, dim, basename), call.head).into_pipeline_data())
    }
}

impl PluginCommand for AnnHnswQuery {
    type Plugin = RagPlugin;

    fn name(&self) -> &str { "rag ann-query-hnsw" }

    fn description(&self) -> &str { "Query an HNSW index and return top-k neighbors with cosine scores" }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named("index", SyntaxShape::String, "Index file path", Some('i'))
            .named("map", SyntaxShape::String, "Index map JSON path", Some('m'))
            .named("query", SyntaxShape::List(Box::new(SyntaxShape::Number)), "Query embedding vector", Some('q'))
            .named("k", SyntaxShape::Int, "Top-k results (default 5)", Some('k'))
            .named("ef-search", SyntaxShape::Int, "ef_search for HNSW (default 200)", None)
            .input_output_type(Type::Any, Type::Any)
    }

    fn run(&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData) -> Result<PipelineData, LabeledError> {
        let index_path = call.get_flag::<String>("index").map_err(|e| LabeledError::new(format!("--index: {}", e)))?.ok_or_else(|| LabeledError::new("--index required"))?;
        let map_path = call.get_flag::<String>("map").map_err(|e| LabeledError::new(format!("--map: {}", e)))?.ok_or_else(|| LabeledError::new("--map required"))?;
        let query_value = call.get_flag::<Value>("query").map_err(|e| LabeledError::new(format!("--query: {}", e)))?.ok_or_else(|| LabeledError::new("--query required"))?;
        let k = call.get_flag::<i64>("k").map_err(|e| LabeledError::new(format!("--k: {}", e)))?.map(|v| v as usize).unwrap_or(5);
        let ef_search = call.get_flag::<i64>("ef-search").map_err(|e| LabeledError::new(format!("--ef-search: {}", e)))?.map(|v| v as usize).unwrap_or(200);

        let qvec = Similarity::extract_vec(&query_value).ok_or_else(|| LabeledError::new("--query must be a list of numbers"))?;
        // normalize query
        let mut qnorm = qvec.clone(); let mut norm = 0.0f32; for &x in qvec.iter() { norm += x*x; }; if norm>0.0 { norm = norm.sqrt(); for v in qnorm.iter_mut() { *v /= norm; } }

        // load id map
        let map_file = File::open(&map_path).map_err(|e| LabeledError::new(format!("Failed to open map file: {}", e)))?;
        let ids: Vec<String> = serde_json::from_reader(map_file).map_err(|e| LabeledError::new(format!("Failed to parse map file: {}", e)))?;

        // load hnsw index via HnswIo (reload from dumped files)
        use anndists::dist::distances::DistCosine;
        use hnsw_rs::hnswio::HnswIo;

        let index_path = Path::new(&index_path);
        let dir = index_path.parent().unwrap_or(Path::new("."));
        let basename = index_path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let mut reloader = HnswIo::new(dir, basename);
        let hnsw: hnsw_rs::hnsw::Hnsw<f32, DistCosine> = reloader.load_hnsw::<f32, DistCosine>().map_err(|e| LabeledError::new(format!("Failed to load HNSW index: {}", e)))?;

        // search uses hnsw.search(&[f32], k, ef_search)
        let neighbours = hnsw.search(&qnorm, k, ef_search);

        let mut out: Vec<Value> = Vec::new();
        for nb in neighbours {
            let idx = nb.d_id; // origin id (our index id)
            let score = nb.distance;
            let id = ids.get(idx).cloned().unwrap_or_default();
            let mut rec = nu_protocol::Record::new();
            rec.push("id".to_string(), Value::string(id, call.head));
            rec.push("index".to_string(), Value::int(idx as i64, call.head));
            rec.push("score".to_string(), Value::float(score as f64, call.head));
            out.push(Value::record(rec, call.head));
        }

        Ok(out.into_pipeline_data(call.head, nu_protocol::Signals::empty()))
    }
}
