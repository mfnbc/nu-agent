use std::fs;
use std::path::PathBuf;

use nu_protocol::Value;

use nu_plugin_rag::commands::embed::Embed;
use nu_plugin_rag::state::{DocRecord, IndexBucket, RagPlugin};

fn collect_md_files(root: &PathBuf, max: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        if out.len() >= max {
            break;
        }
        if let Ok(entries) = fs::read_dir(&dir) {
            for e in entries.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else if let Some(ext) = p.extension() {
                    if ext == "md" {
                        out.push(p);
                        if out.len() >= max {
                            break;
                        }
                    }
                }
            }
        }
    }
    out
}

fn main() {
    // Build a small in-memory index from a handful of nushell docs using mock embeddings
    let cwd = std::env::current_dir().unwrap();
    let docs_root = cwd.join("external/nushell.github.io");
    eprintln!("Looking for docs under: {}", docs_root.display());

    let files = collect_md_files(&docs_root, 20);
    eprintln!("Found {} markdown files (using up to 20)", files.len());

    let plugin = RagPlugin::new();
    let mut lock = plugin.indexes.lock().unwrap();
    let mut bucket = IndexBucket::default();

    let dim = 128usize; // smaller dim for speed
    for p in files.iter() {
        if let Ok(s) = fs::read_to_string(p) {
            let id = p.to_string_lossy().to_string();
            let emb = Embed::deterministic_embedding(&s, dim);
            let mut rec = nu_protocol::Record::new();
            rec.push(
                "id".to_string(),
                Value::string(id.clone(), nu_protocol::Span::unknown()),
            );
            rec.push(
                "text".to_string(),
                Value::string(s.clone(), nu_protocol::Span::unknown()),
            );
            bucket.dimension = Some(dim);
            bucket.docs.push(DocRecord {
                id,
                embedding: emb,
                value: Value::Record {
                    val: Box::new(rec),
                    internal_span: nu_protocol::Span::unknown(),
                },
            });
        }
    }

    lock.insert("nushell_docs".to_string(), bucket.clone());
    drop(lock);

    // Run a query
    let query = "plugin".to_string();
    let qemb = Embed::deterministic_embedding(&query, dim);

    let lock2 = plugin.indexes.lock().unwrap();
    let b = lock2.get("nushell_docs").unwrap();
    let mut scores: Vec<(String, f32, Value)> = b
        .docs
        .iter()
        .map(|d| {
            let score: f32 = d.embedding.iter().zip(&qemb).map(|(a, b)| a * b).sum();
            (d.id.clone(), score, d.value.clone())
        })
        .collect();
    scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    eprintln!("Top 5 hits for query '{}':", query);
    for (id, score, val) in scores.into_iter().take(5) {
        let text_preview = match &val {
            Value::Record { val, .. } => val
                .get("text")
                .and_then(|v| v.coerce_string().ok())
                .unwrap_or_else(|| "<no text>".to_string()),
            other => other
                .coerce_string()
                .unwrap_or_else(|_| "<non-string>".to_string()),
        };
        println!(
            "{:.4}\t{}\n{}\n---",
            score,
            id,
            &text_preview[..std::cmp::min(200, text_preview.len())]
        );
    }
}
