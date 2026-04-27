use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{
    IntoInterruptiblePipelineData, LabeledError, PipelineData, Signals, Signature, SyntaxShape,
    Type, Value,
};
use pulldown_cmark::{Event, Parser, Tag};
use text_splitter::{ChunkConfig, TextSplitter};
use tokenizers::Tokenizer;

use crate::state::RagPlugin;

pub struct Shred;

impl Shred {
    fn chunk_text_with_tokenizer(
        text: &str,
        tok: Tokenizer,
        max_tokens: usize,
        overlap: usize,
    ) -> Result<Vec<String>, String> {
        let mut cfg = ChunkConfig::new(max_tokens).with_sizer(tok);
        cfg = cfg
            .with_overlap(overlap)
            .map_err(|e| format!("with_overlap: {}", e))?;
        let splitter = TextSplitter::new(cfg);
        Ok(splitter.chunks(text).map(|s| s.to_string()).collect())
    }

    fn load_tokenizer_from_file(path: &str) -> Result<Tokenizer, String> {
        Tokenizer::from_file(path).map_err(|e| format!("loading tokenizer from '{}': {}", path, e))
    }

    fn load_tokenizer_pretrained(name: &str) -> Result<Tokenizer, String> {
        Tokenizer::from_pretrained(name, None)
            .map_err(|e| format!("loading tokenizer '{}': {}", name, e))
    }

    fn chunk_text_by_chars(text: &str, max_chars: usize, overlap: usize) -> Vec<String> {
        if text.chars().count() <= max_chars {
            return vec![text.to_string()];
        }
        let mut out = Vec::new();
        let step = if max_chars > overlap {
            max_chars - overlap
        } else {
            max_chars
        };
        let mut start = 0usize;
        let chars: Vec<char> = text.chars().collect();
        while start < chars.len() {
            let end = usize::min(start + max_chars, chars.len());
            let s: String = chars[start..end].iter().collect();
            out.push(s);
            if end == chars.len() {
                break;
            }
            start += step;
        }
        out
    }

    fn extract_title_and_text(md: &str) -> (String, String) {
        let parser = Parser::new(md);
        let mut title = String::new();
        let mut in_heading = false;
        let mut text_acc = String::new();
        for ev in parser {
            match ev {
                Event::Start(Tag::Heading(..)) => in_heading = true,
                Event::End(Tag::Heading(..)) => in_heading = false,
                Event::Text(t) => {
                    if in_heading && title.is_empty() {
                        title = t.to_string();
                    }
                    text_acc.push_str(&t);
                }
                Event::Code(t) => text_acc.push_str(&t),
                _ => {}
            }
        }
        (title, text_acc)
    }
}

impl PluginCommand for Shred {
    type Plugin = RagPlugin;

    fn name(&self) -> &str {
        "rag shred"
    }

    fn description(&self) -> &str {
        "Chunk markdown text into tokenizer-aware pieces sized for an embedding model. Reads text from the pipeline; emits chunk records."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .named(
                "source",
                SyntaxShape::String,
                "Source path tag attached to each chunk record",
                Some('s'),
            )
            .named(
                "max-tokens",
                SyntaxShape::Int,
                "Max tokens per chunk (default 480)",
                None,
            )
            .named(
                "overlap-tokens",
                SyntaxShape::Int,
                "Token overlap between chunks (default 50)",
                None,
            )
            .named(
                "tokenizer-path",
                SyntaxShape::String,
                "Path to a local tokenizer.json (preferred — avoids HuggingFace fetch)",
                None,
            )
            .named(
                "tokenizer",
                SyntaxShape::String,
                "HuggingFace tokenizer name to fetch (default mixedbread-ai/mxbai-embed-large-v1)",
                None,
            )
            .switch(
                "prepend-passage",
                "Prefix each chunk with 'passage: ' for asymmetric retrieval models",
                None,
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
        let source = call
            .get_flag::<String>("source")
            .map_err(|e| LabeledError::new(format!("--source: {}", e)))?
            .unwrap_or_default();
        let max_tokens = call
            .get_flag::<i64>("max-tokens")
            .map_err(|e| LabeledError::new(format!("--max-tokens: {}", e)))?
            .map(|v| v as usize)
            .unwrap_or(480);
        let overlap_tokens = call
            .get_flag::<i64>("overlap-tokens")
            .map_err(|e| LabeledError::new(format!("--overlap-tokens: {}", e)))?
            .map(|v| v as usize)
            .unwrap_or(50);
        let tokenizer_path = call
            .get_flag::<String>("tokenizer-path")
            .map_err(|e| LabeledError::new(format!("--tokenizer-path: {}", e)))?;
        let tokenizer_name = call
            .get_flag::<String>("tokenizer")
            .map_err(|e| LabeledError::new(format!("--tokenizer: {}", e)))?
            .unwrap_or_else(|| "mixedbread-ai/mxbai-embed-large-v1".to_string());
        let prepend_passage = call
            .has_flag("prepend-passage")
            .map_err(|e| LabeledError::new(format!("--prepend-passage: {}", e)))?;

        let raw_value = input
            .into_value(call.head)
            .map_err(|e| LabeledError::new(format!("read pipeline input: {}", e)))?;
        let raw = match raw_value {
            Value::String { val, .. } => val,
            other => {
                return Err(LabeledError::new(format!(
                    "rag shred expects string input (try `open file.md | rag shred`); got {}",
                    other.get_type()
                )));
            }
        };

        let (title, text) = Self::extract_title_and_text(&raw);

        let tokenizer_result: Result<Tokenizer, String> = if let Some(path) = tokenizer_path.as_ref() {
            Self::load_tokenizer_from_file(path)
        } else {
            Self::load_tokenizer_pretrained(&tokenizer_name)
        };

        let chunks = match tokenizer_result
            .and_then(|tok| Self::chunk_text_with_tokenizer(&text, tok, max_tokens, overlap_tokens))
        {
            Ok(c) => c,
            Err(e) => {
                eprintln!(
                    "rag shred: tokenizer split failed ({}); falling back to char-based",
                    e
                );
                // Conservative defaults sized to fit within mxbai-embed-large-v1's 512-token
                // context with margin for code-heavy content (which tokenizes denser than prose).
                Self::chunk_text_by_chars(&text, 1500, 100)
            }
        };

        let mut out: Vec<Value> = Vec::with_capacity(chunks.len());
        for chunk in chunks {
            let embedding_input = if prepend_passage {
                format!("passage: {}", chunk)
            } else {
                chunk.clone()
            };
            let id = blake3::hash(embedding_input.as_bytes()).to_hex().to_string();

            let mut rec = nu_protocol::Record::new();
            rec.push("id".to_string(), Value::string(id, call.head));
            rec.push("source".to_string(), Value::string(source.clone(), call.head));
            rec.push("title".to_string(), Value::string(title.clone(), call.head));
            rec.push("text".to_string(), Value::string(chunk, call.head));
            rec.push(
                "embedding_input".to_string(),
                Value::string(embedding_input, call.head),
            );

            out.push(Value::record(rec, call.head));
        }

        Ok(out.into_pipeline_data(call.head, Signals::empty()))
    }
}
