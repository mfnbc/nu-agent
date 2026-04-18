use anyhow::Result;
use clap::Parser;
use nu_plugin_rag::{deterministic_embed, read_embedding_input, write_embeddings, EmbeddingOut};
use std::path::PathBuf;

// Optional dependencies gated at runtime: tract & tokenizers are added in Cargo.toml
use tokenizers::Tokenizer;
use tract_onnx::prelude::*;

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Deterministic embedding runner (placeholder)"
)]
struct Args {
    /// Input embedding_input.jsonl
    #[arg(long)]
    input: String,

    /// Output embeddings.jsonl
    #[arg(long)]
    output: String,

    /// Embedding dimension
    #[arg(long, default_value_t = 128)]
    dim: usize,
    /// Engine to use: deterministic or tract
    #[arg(long, default_value = "deterministic")]
    engine: String,

    /// Path to ONNX model (required if engine=tract)
    #[arg(long)]
    model_path: Option<PathBuf>,

    /// Path to tokenizer.json (optional; required for some models)
    #[arg(long)]
    tokenizer_path: Option<PathBuf>,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let records = read_embedding_input(&args.input)?;

    let embeddings = if args.engine.to_lowercase() == "tract" {
        // Try tract path; on any error, fall back to deterministic
        match run_tract(&records, &args.model_path, &args.tokenizer_path, args.dim) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "Tract inference failed, falling back to deterministic embedder: {}",
                    e
                );
                records
                    .into_iter()
                    .map(|r| EmbeddingOut {
                        id: r.id,
                        embedding: deterministic_embed(&r.text, args.dim),
                    })
                    .collect()
            }
        }
    } else {
        records
            .into_iter()
            .map(|r| EmbeddingOut {
                id: r.id,
                embedding: deterministic_embed(&r.text, args.dim),
            })
            .collect()
    };

    write_embeddings(&args.output, &embeddings)?;

    println!("{{\"status\":\"ok\",\"written\":{}}}", embeddings.len());
    Ok(())
}

/// Run tract ONNX inference for the provided records.
fn run_tract(
    records: &Vec<nu_plugin_rag::EmbeddingRecord>,
    model_path: &Option<PathBuf>,
    tokenizer_path: &Option<PathBuf>,
    dim: usize,
) -> Result<Vec<EmbeddingOut>> {
    let model_path = model_path
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("model_path required for tract engine"))?;

    // Load tokenizer if provided
    let tokenizer = if let Some(tpath) = tokenizer_path {
        match Tokenizer::from_file(tpath) {
            Ok(t) => Some(t),
            Err(e) => {
                eprintln!("Warning: failed to load tokenizer: {}", e);
                None
            }
        }
    } else {
        None
    };

    // Load ONNX model
    let model = tract_onnx::onnx().model_for_path(model_path)?;
    // Make the model runnable
    let mut prog = model.into_optimized()?;
    let runnable = prog.into_runnable()?;

    // For now, we'll assume the model accepts input_ids and attention_mask as i64 tensors named appropriately.
    // We'll try a simple path: tokenize texts to ids (if tokenizer available) or use naive byte encoding.

    // Prepare inputs
    let mut outs: Vec<EmbeddingOut> = Vec::with_capacity(records.len());

    for rec in records {
        let input_ids: Vec<i64> = if let Some(ref tok) = tokenizer {
            let enc = tok
                .encode(rec.text.clone(), true)
                .map_err(|e| anyhow::anyhow!(e))?;
            enc.get_ids().iter().map(|&v| v as i64).collect()
        } else {
            // fallback: simple utf8 bytes as ints (not ideal)
            rec.text.bytes().map(|b| b as i64).collect()
        };

        // Pad/truncate to a small fixed length to keep things simple
        let max_len = 128usize;
        let mut input_padded = input_ids.clone();
        input_padded.resize(max_len, 0);

        // Convert to tensor
        let tensor = ndarray::Array2::from_shape_vec(
            (1, max_len),
            input_padded.iter().map(|&x| x as i64).collect(),
        )?;
        let tensor = tensor.into_tensor();

        // Run
        let result = runnable.run(tvec!(tensor))?;

        // Assume first output is embedding vector
        let output = &result[0];
        let slice: Vec<f32> = output.to_array_view::<f32>()?.iter().cloned().collect();

        // If needed, normalize or pad/truncate to dim
        let mut v = slice;
        v.resize(dim, 0.0);

        outs.push(EmbeddingOut {
            id: rec.id.clone(),
            embedding: v,
        });
    }

    Ok(outs)
}
