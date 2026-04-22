use std::fs;
use std::path::PathBuf;
use std::time::Instant;

use nu_plugin_rag::commands::embed::Embed;
use nu_plugin_rag::state::{DocRecord, IndexBucket, RagPlugin};
use nu_protocol::Value;
use walkdir::WalkDir;

fn collect_md(root: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let rootp = PathBuf::from(root);
    if !rootp.exists() {
        return out;
    }
    for entry in walkdir::WalkDir::new(rootp)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let p = entry.path();
        if p.is_file() {
            if let Some(ext) = p.extension() {
                if ext == "md" {
                    out.push(p.to_path_buf());
                }
            }
        }
    }
    out
}

fn main() {
    let root = "external/nushell.github.io";
    let files = collect_md(root);
    eprintln!("Found {} markdown files", files.len());
    let plugin = RagPlugin::new();
    let mut lock = plugin.indexes.lock().unwrap();
    let mut bucket = IndexBucket::default();
    let dim = 256usize;
    let mut count: usize = 0;
    let start = Instant::now();
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
            if bucket.dimension.is_none() {
                bucket.dimension = Some(dim);
            }
            bucket.docs.push(DocRecord {
                id,
                embedding: emb,
                value: Value::Record {
                    val: Box::new(rec),
                    internal_span: nu_protocol::Span::unknown(),
                },
            });
            count += 1;
            if count % 500 == 0 {
                eprintln!("Ingested {} docs...", count);
            }
        }
    }
    lock.insert("nu_docs_full".to_string(), bucket.clone());
    drop(lock);
    let elapsed = start.elapsed();
    eprintln!("Ingest complete: {} docs in {:?}", count, elapsed);

    // print stats
    let lock2 = plugin.indexes.lock().unwrap();
    if let Some(b) = lock2.get("nu_docs_full") {
        let c = b.docs.len();
        let dim = b.dimension.unwrap_or(0);
        let est = (c as u64) * (dim as u64) * 4u64;
        eprintln!(
            "Index stats: count={}, dim={}, est_mem_bytes={}",
            c, dim, est
        );

        // run a sample query
        let query = "completion".to_string();
        let qemb = Embed::deterministic_embedding(&query, dim);
        let mut scores: Vec<(String, f32)> = b
            .docs
            .iter()
            .map(|d| {
                let score: f32 = d.embedding.iter().zip(&qemb).map(|(a, b)| a * b).sum();
                (d.id.clone(), score)
            })
            .collect();
        scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        eprintln!("Top 5 hits for '{}':", query);
        for (id, score) in scores.into_iter().take(5) {
            println!("{:.4}\t{}", score, id);
        }
    }
}
