use crate::state::RagPlugin;
use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{
    IntoInterruptiblePipelineData, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value,
};

pub struct IndexCreate;
pub struct IndexAdd;
pub struct IndexSearch;
pub struct IndexStats;
pub struct IndexSave;
pub struct IndexLoad;
pub struct IndexList;
pub struct IndexRemove;

impl PluginCommand for IndexCreate {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-create"
    }

    fn usage(&self) -> &str {
        "Create an in-memory index bucket"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .input_output_type(Type::Nothing, Type::Nothing)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let mut idx = plugin.indexes.lock().unwrap();
        idx.insert(name, crate::state::IndexBucket::default());
        Ok(PipelineData::Empty)
    }
}

impl PluginCommand for IndexSave {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-save"
    }

    fn usage(&self) -> &str {
        "Save an in-memory index to a MessagePack file"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .named(
                "path",
                SyntaxShape::String,
                "File path to write the index to",
                Some('p'),
            )
            .input_output_type(Type::Nothing, Type::Nothing)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let path = call
            .get_flag::<String>("path")
            .map_err(|e| LabeledError::new(format!("failed to read path flag: {}", e)))?
            .ok_or_else(|| LabeledError::new("--path is required"))?;

        let lock = plugin.indexes.lock().unwrap();
        let bucket = lock
            .get(&name)
            .ok_or_else(|| LabeledError::new(format!("index '{}' not found", name)))?;

        // Build a compact serializable structure
        #[derive(serde::Serialize)]
        struct SavedDoc<'a> {
            id: &'a str,
            vector: &'a [f32],
            value: &'a nu_protocol::Value,
        }

        #[derive(serde::Serialize)]
        struct SavedBucket<'a> {
            dimension: Option<usize>,
            docs: Vec<SavedDoc<'a>>,
        }

        let docs: Vec<SavedDoc> = bucket
            .docs
            .iter()
            .map(|d| SavedDoc {
                id: &d.id,
                vector: &d.embedding,
                value: &d.value,
            })
            .collect();

        let sb = SavedBucket {
            dimension: bucket.dimension,
            docs,
        };

        let buf = match rmp_serde::to_vec_named(&sb) {
            Ok(b) => b,
            Err(e) => return Err(LabeledError::new(format!("serialize error: {}", e))),
        };

        match std::fs::write(&path, &buf) {
            Ok(_) => Ok(PipelineData::Empty),
            Err(e) => Err(LabeledError::new(format!(
                "failed to write {}: {}",
                path, e
            ))),
        }
    }
}

impl PluginCommand for IndexLoad {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-load"
    }

    fn usage(&self) -> &str {
        "Load an index from a MessagePack file into memory"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .named(
                "path",
                SyntaxShape::String,
                "File path to read the index from",
                Some('p'),
            )
            .input_output_type(Type::Nothing, Type::Nothing)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let path = call
            .get_flag::<String>("path")
            .map_err(|e| LabeledError::new(format!("failed to read path flag: {}", e)))?
            .ok_or_else(|| LabeledError::new("--path is required"))?;

        let buf = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => return Err(LabeledError::new(format!("failed to read {}: {}", path, e))),
        };

        // Define deserializable shapes matching SavedBucket
        #[derive(serde::Deserialize)]
        struct SavedDoc {
            id: String,
            vector: Vec<f32>,
            value: nu_protocol::Value,
        }

        #[derive(serde::Deserialize)]
        struct SavedBucket {
            dimension: Option<usize>,
            docs: Vec<SavedDoc>,
        }

        let sb: SavedBucket = match rmp_serde::from_slice(&buf) {
            Ok(s) => s,
            Err(e) => return Err(LabeledError::new(format!("deserialize error: {}", e))),
        };

        let mut docs: Vec<crate::state::DocRecord> = Vec::with_capacity(sb.docs.len());
        for d in sb.docs.into_iter() {
            docs.push(crate::state::DocRecord {
                id: d.id,
                embedding: d.vector,
                value: d.value,
            });
        }

        let mut lock = plugin.indexes.lock().unwrap();
        lock.insert(
            name,
            crate::state::IndexBucket {
                dimension: sb.dimension,
                docs,
            },
        );

        Ok(PipelineData::Empty)
    }
}

impl PluginCommand for IndexAdd {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-add"
    }

    fn usage(&self) -> &str {
        "Add embedded records into an index"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .named(
                "batch-size",
                SyntaxShape::Int,
                "Buffer size for batched index-add (lock once per batch)",
                Some('b'),
            )
            .named(
                "quiet",
                SyntaxShape::Boolean,
                "Suppress progress messages",
                Some('q'),
            )
            .input_output_type(Type::ListStream, Type::Nothing)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let span = call.head;
        let name = call.req::<String>(0).map_err(LabeledError::from)?;

        let batch_size = call
            .get_flag::<i64>("batch-size")
            .map_err(|e| LabeledError::new(format!("failed to read batch-size: {}", e)))?
            .unwrap_or(100) as usize;
        let quiet = call
            .has_flag("quiet")
            .map_err(|e| LabeledError::new(format!("failed to read quiet flag: {}", e)))?;

        // We'll collect valid DocRecord entries into a buffer and flush them to the
        // index under a single lock per batch to reduce contention.
        let mut buffer: Vec<crate::state::DocRecord> = Vec::with_capacity(batch_size);
        let mut inserted: usize = 0;

        for v in input.into_iter() {
            match v {
                Value::Record { val, .. } => {
                    let rec = *val;
                    // expect an "embedding" column that is a list of floats
                    if let Some(emb_val) = rec.get("embedding") {
                        match emb_val {
                            Value::List { vals, .. } => {
                                let mut vec_f = Vec::with_capacity(vals.len());
                                let mut ok = true;
                                for item in vals.iter() {
                                    if let Value::Float { val: f, .. } = item {
                                        vec_f.push(*f as f32);
                                    } else {
                                        ok = false;
                                        break;
                                    }
                                }
                                if ok {
                                    // id: try to find an "id" field else generate one
                                    let id = rec
                                        .get("id")
                                        .and_then(|v| match v {
                                            Value::String { val, .. } => Some(val.clone()),
                                            _ => None,
                                        })
                                        .unwrap_or_else(|| {
                                            format!("doc-{}", inserted + buffer.len())
                                        });

                                    buffer.push(crate::state::DocRecord {
                                        id,
                                        embedding: vec_f,
                                        value: Value::Record {
                                            val: Box::new(rec.clone()),
                                            internal_span: span,
                                        },
                                    });

                                    if buffer.len() >= batch_size {
                                        // flush buffer to index
                                        let mut lock = plugin.indexes.lock().unwrap();
                                        let bucket = lock
                                            .entry(name.clone())
                                            .or_insert_with(crate::state::IndexBucket::default);
                                        // ensure dimension compatibility
                                        if let Some(dim) = bucket.dimension {
                                            buffer.retain(|d| {
                                                if d.embedding.len() != dim {
                                                    if !quiet {
                                                        eprintln!("rag index-add: skipping record with embedding dimension {} but index expects {}", d.embedding.len(), dim);
                                                    }
                                                    false
                                                } else {
                                                    true
                                                }
                                            });
                                        } else if let Some(first) = buffer.get(0) {
                                            bucket.dimension = Some(first.embedding.len());
                                        }
                                        bucket.docs.extend(buffer.drain(..));
                                        inserted += batch_size;
                                        if !quiet {
                                            eprintln!(
                                                "rag index-add: inserted {} documents...",
                                                inserted
                                            );
                                        }
                                    }
                                } else if !quiet {
                                    eprintln!(
                                        "rag index-add: skipping record with non-float embedding"
                                    );
                                }
                            }
                            Value::Error { .. } => {
                                if !quiet {
                                    eprintln!(
                                        "rag index-add: skipping record with embedding error"
                                    );
                                }
                            }
                            _ => {
                                if !quiet {
                                    eprintln!(
                                        "rag index-add: skipping record without proper embedding"
                                    );
                                }
                            }
                        }
                    } else if !quiet {
                        eprintln!("rag index-add: skipping record missing embedding");
                    }
                }
                other => {
                    if !quiet {
                        eprintln!("rag index-add: skipping non-record value: {:?}", other);
                    }
                }
            }
        }

        // flush remaining buffer
        if !buffer.is_empty() {
            let mut lock = plugin.indexes.lock().unwrap();
            let bucket = lock
                .entry(name.clone())
                .or_insert_with(crate::state::IndexBucket::default);
            if let Some(dim) = bucket.dimension {
                buffer.retain(|d| {
                    if d.embedding.len() != dim {
                        if !quiet {
                            eprintln!("rag index-add: skipping record with embedding dimension {} but index expects {}", d.embedding.len(), dim);
                        }
                        false
                    } else {
                        true
                    }
                });
            } else if let Some(first) = buffer.get(0) {
                bucket.dimension = Some(first.embedding.len());
            }
            let leftover = buffer.len();
            bucket.docs.extend(buffer.drain(..));
            inserted += leftover;
            if !quiet {
                eprintln!("rag index-add: inserted {} documents (final)", inserted);
            }
        }

        Ok(PipelineData::Empty)
    }
}

impl PluginCommand for IndexSearch {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-search"
    }

    fn usage(&self) -> &str {
        "Search an in-memory index by vector or by text query"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .named("k", SyntaxShape::Int, "number of hits to return", Some('k'))
            .named(
                "query-vector",
                SyntaxShape::List(Box::new(SyntaxShape::Number)),
                "Provide an explicit query vector (list of numbers)",
                Some('q'),
            )
            .named(
                "mock",
                SyntaxShape::Boolean,
                "Use deterministic mock embeddings for text queries",
                Some('m'),
            )
            .named(
                "url",
                SyntaxShape::String,
                "Embedding API URL to use for live text queries",
                Some('u'),
            )
            .named(
                "model",
                SyntaxShape::String,
                "Embedding model name for live text queries",
                Some('o'),
            )
            .named(
                "with-doc",
                SyntaxShape::Boolean,
                "Include the original document value in results",
                Some('w'),
            )
            .named(
                "field",
                SyntaxShape::String,
                "When used with --with-doc, return only this field from the stored doc",
                Some('f'),
            )
            .input_output_type(Type::Nothing, Type::ListStream)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let k = call
            .get_flag::<i64>("k")
            .map_err(|e| LabeledError::new(format!("failed to read k: {}", e)))?
            .unwrap_or(5) as usize;

        // read flags for query handling
        let mock = call
            .has_flag("mock")
            .map_err(|e| LabeledError::new(format!("failed to read mock flag: {}", e)))?;
        let url = call
            .get_flag::<String>("url")
            .map_err(|e| LabeledError::new(format!("failed to read url flag: {}", e)))?
            .unwrap_or_else(|| "http://172.19.224.1:1234/v1/embeddings".to_string());
        let model = call
            .get_flag::<String>("model")
            .map_err(|e| LabeledError::new(format!("failed to read model flag: {}", e)))?
            .unwrap_or_else(|| "text-embedding-mxbai-embed-large-v1".to_string());

        // Optional query-vector flag (list of numbers) or positional text query
        let qvec_flag = call
            .get_flag::<Value>("query-vector")
            .map_err(|e| LabeledError::new(format!("failed to read query-vector: {}", e)))?;

        // positional optional text query is at index 1; call.req returns Err if missing
        let maybe_text_opt = call.req::<String>(1).ok();
        let maybe_text = maybe_text_opt.map(|s| Value::string(s, call.head));

        let with_doc = call
            .has_flag("with-doc")
            .map_err(|e| LabeledError::new(format!("failed to read with-doc flag: {}", e)))?;

        let field = call
            .get_flag::<String>("field")
            .map_err(|e| LabeledError::new(format!("failed to read field flag: {}", e)))?
            .map(|s| s.to_string());

        let lock = plugin.indexes.lock().unwrap();
        let bucket = match lock.get(&name) {
            Some(b) => b.clone(),
            None => return Ok(Vec::<Value>::new().into_pipeline_data(None)),
        };

        // Build query vector either from --query-vector, text positional arg, or error
        let query: Vec<f32> = if let Some(v) = qvec_flag {
            // convert Value into Vec<f32>
            match v {
                Value::List { vals, .. } => {
                    let mut out = Vec::with_capacity(vals.len());
                    for item in vals.iter() {
                        match item {
                            Value::Float { val, .. } => out.push(*val as f32),
                            Value::Int { val, .. } => out.push(*val as f32),
                            other => {
                                return Err(LabeledError::new(format!(
                                    "query-vector must be a list of numbers; got {}",
                                    other.get_type()
                                )));
                            }
                        }
                    }
                    out
                }
                other => {
                    return Err(LabeledError::new(format!(
                        "query-vector must be a list; got {}",
                        other.get_type()
                    )));
                }
            }
        } else if let Some(val) = maybe_text {
            // we have a positional text query
            let text = match val {
                Value::String { val, .. } => val.clone(),
                other => other
                    .coerce_string()
                    .unwrap_or_else(|_| format!("{:?}", other)),
            };

            if mock {
                // use same default dim as embed command
                let dim = 768usize;
                crate::commands::embed::Embed::deterministic_embedding(&text, dim)
            } else {
                // call HTTP embed helper for single text
                let client = reqwest::blocking::Client::new();
                match crate::commands::embed::Embed::http_embed_texts(
                    &client,
                    &url,
                    &model,
                    &vec![text],
                ) {
                    Ok(mut v) => v.pop().unwrap_or_else(|| vec![]),
                    Err(e) => return Err(e),
                }
            }
        } else {
            // no query provided: use zero vector
            vec![0.0f32; bucket.docs.get(0).map(|d| d.embedding.len()).unwrap_or(0)]
        };

        // validate dimension using per-index metadata if present
        if let Some(dim) = bucket.dimension {
            if query.len() != dim {
                return Err(LabeledError::new(format!(
                    "query vector dimension {} does not match index dimension {}",
                    query.len(),
                    dim
                )));
            }
        } else if let Some(first) = bucket.docs.get(0) {
            if query.len() != first.embedding.len() {
                return Err(LabeledError::new(format!(
                    "query vector dimension {} does not match index dimension {}",
                    query.len(),
                    first.embedding.len()
                )));
            }
        }

        let mut scores: Vec<(String, f32, Value)> = bucket
            .docs
            .into_iter()
            .map(|d| {
                let score: f32 = d.embedding.iter().zip(&query).map(|(a, b)| a * b).sum();
                (d.id, score, d.value)
            })
            .collect();

        scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let out: Vec<Value> = scores
            .into_iter()
            .take(k)
            .map(|(id, score, doc_val)| {
                let mut rec = nu_protocol::Record::new();
                rec.push("id".to_string(), Value::string(id, call.head));
                rec.push("score".to_string(), Value::float(score as f64, call.head));
                if with_doc {
                    // If a specific field was requested and the stored doc is a record,
                    // attempt to extract that field. Otherwise, include the full stored value.
                    let doc_to_push = if let Some(field_name) = field.as_ref() {
                        match &doc_val {
                            Value::Record { val, .. } => {
                                let map = &**val;
                                map.get(field_name)
                                    .cloned()
                                    .unwrap_or_else(|| Value::nothing(call.head))
                            }
                            // If the stored value is not a record, return it directly (best-effort)
                            other => other.clone(),
                        }
                    } else {
                        doc_val
                    };

                    rec.push("doc".to_string(), doc_to_push);
                }
                Value::Record {
                    val: Box::new(rec),
                    internal_span: call.head,
                }
            })
            .collect();

        Ok(out.into_pipeline_data(None))
    }
}

impl PluginCommand for IndexStats {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-stats"
    }

    fn usage(&self) -> &str {
        "Show statistics for an in-memory index"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .input_output_type(Type::Nothing, Type::ListStream)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let lock = plugin.indexes.lock().unwrap();
        if let Some(bucket) = lock.get(&name) {
            let count = bucket.docs.len() as i64;
            let dim = bucket.dimension.map(|d| d as i64).unwrap_or(0);
            // estimate memory: count * dim * 4 (f32 bytes)
            let est_mem = (count as i64) * (dim as i64) * 4i64;

            let mut rec = nu_protocol::Record::new();
            rec.push("name".to_string(), Value::string(name, call.head));
            rec.push("count".to_string(), Value::int(count, call.head));
            rec.push("dimension".to_string(), Value::int(dim, call.head));
            rec.push("est_mem_bytes".to_string(), Value::int(est_mem, call.head));

            let out = Value::Record {
                val: Box::new(rec),
                internal_span: call.head,
            };

            Ok(vec![out].into_pipeline_data(None))
        } else {
            Ok(Vec::<Value>::new().into_pipeline_data(None))
        }
    }
}

impl PluginCommand for IndexList {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-list"
    }

    fn usage(&self) -> &str {
        "List all active in-memory indexes"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name()).input_output_type(Type::Nothing, Type::ListStream)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let lock = plugin.indexes.lock().unwrap();
        let mut out: Vec<Value> = Vec::with_capacity(lock.len());

        for (name, bucket) in lock.iter() {
            let count = bucket.docs.len() as i64;
            let dim = bucket.dimension.map(|d| d as i64).unwrap_or(0);
            let est_mem = (count as i64) * (dim as i64) * 4i64;

            let mut rec = nu_protocol::Record::new();
            rec.push("name".to_string(), Value::string(name.clone(), call.head));
            rec.push("count".to_string(), Value::int(count, call.head));
            rec.push("dimension".to_string(), Value::int(dim, call.head));
            rec.push("est_mem_bytes".to_string(), Value::int(est_mem, call.head));

            out.push(Value::Record {
                val: Box::new(rec),
                internal_span: call.head,
            });
        }

        Ok(out.into_pipeline_data(None))
    }
}

impl PluginCommand for IndexRemove {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag index-remove"
    }

    fn usage(&self) -> &str {
        "Remove an in-memory index and free its memory"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("name", SyntaxShape::String, "index name")
            .input_output_type(Type::Nothing, Type::Nothing)
    }

    fn run(
        &self,
        plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        _input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let name = call.req::<String>(0).map_err(LabeledError::from)?;
        let mut lock = plugin.indexes.lock().unwrap();
        if lock.remove(&name).is_some() {
            // Successfully removed
            Ok(PipelineData::Empty)
        } else {
            Err(LabeledError::new(format!("index '{}' not found", name)))
        }
    }
}
