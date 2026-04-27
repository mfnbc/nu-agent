use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{
    IntoInterruptiblePipelineData, LabeledError, PipelineData, Signals, Signature, SyntaxShape,
    Type, Value,
};

use crate::state::RagPlugin;

pub struct Similarity;

impl Similarity {
    fn extract_vec(value: &Value) -> Option<Vec<f32>> {
        if let Value::List { vals, .. } = value {
            let mut out = Vec::with_capacity(vals.len());
            for v in vals.iter() {
                match v {
                    Value::Float { val, .. } => out.push(*val as f32),
                    Value::Int { val, .. } => out.push(*val as f32),
                    _ => return None,
                }
            }
            Some(out)
        } else {
            None
        }
    }

    fn cosine(a: &[f32], b: &[f32]) -> f32 {
        if a.len() != b.len() {
            return 0.0;
        }
        let mut dot = 0.0f32;
        let mut na = 0.0f32;
        let mut nb = 0.0f32;
        for i in 0..a.len() {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        let denom = na.sqrt() * nb.sqrt();
        if denom > 0.0 {
            dot / denom
        } else {
            0.0
        }
    }
}

impl PluginCommand for Similarity {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag similarity"
    }

    fn description(&self) -> &str {
        "Score input records against a query vector by cosine similarity; return top-k sorted desc with a `score` field."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named(
                "query",
                SyntaxShape::List(Box::new(SyntaxShape::Number)),
                "Query embedding vector (list of numbers)",
                Some('q'),
            )
            .named(
                "k",
                SyntaxShape::Int,
                "Number of top results to return (default 5)",
                Some('k'),
            )
            .named(
                "field",
                SyntaxShape::String,
                "Embedding field name on input records (default 'embedding')",
                Some('f'),
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
        let query_value = call
            .get_flag::<Value>("query")
            .map_err(|e| LabeledError::new(format!("--query: {}", e)))?
            .ok_or_else(|| LabeledError::new("rag similarity requires --query <list>"))?;

        let query = Self::extract_vec(&query_value)
            .ok_or_else(|| LabeledError::new("--query must be a list of numbers"))?;

        let k = call
            .get_flag::<i64>("k")
            .map_err(|e| LabeledError::new(format!("--k: {}", e)))?
            .map(|v| v as usize)
            .unwrap_or(5);

        let field = call
            .get_flag::<String>("field")
            .map_err(|e| LabeledError::new(format!("--field: {}", e)))?
            .unwrap_or_else(|| "embedding".to_string());

        let mut scored: Vec<(f32, Value)> = Vec::new();
        for v in input.into_iter() {
            let emb_val = match &v {
                Value::Record { val, .. } => val.get(&field).cloned(),
                _ => None,
            };
            let emb_val = match emb_val {
                Some(e) => e,
                None => continue,
            };
            let doc_vec = match Self::extract_vec(&emb_val) {
                Some(d) => d,
                None => continue,
            };
            let score = Self::cosine(&query, &doc_vec);
            scored.push((score, v));
        }

        scored.sort_by(|a, b| {
            b.0.partial_cmp(&a.0)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut out: Vec<Value> = Vec::with_capacity(k.min(scored.len()));
        for (score, v) in scored.into_iter().take(k) {
            let new_v = match v {
                Value::Record { val, .. } => {
                    let mut rec = (*val).clone();
                    rec.push("score".to_string(), Value::float(score as f64, call.head));
                    Value::record(rec, call.head)
                }
                other => other,
            };
            out.push(new_v);
        }

        Ok(out.into_pipeline_data(call.head, Signals::empty()))
    }
}
