use anyhow::Context;
use fastembed::{InitOptions, TextEmbedding};
use rayon::prelude::*;
use rmp_serde::from_slice;
use serde::Deserialize;
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use std::fs;

#[derive(Deserialize)]
struct EmbRec {
    id: String,
    vector: Vec<f32>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct ChunkRec {
    id: String,
    path: String,
    taxonomy: Option<Taxonomy>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
struct Taxonomy {
    idiom_weight: Option<i32>,
}

fn build_index(vec_path: &str, chunks_path: &str, out_index: &str) -> anyhow::Result<()> {
    // Read vectors (support multiple machine-only MessagePack formats)
    let buf = fs::read(vec_path).context("read vectors")?;

    // First try: MessagePack array of EmbRec { id, vector }
    let vecs: Vec<EmbRec> = match from_slice::<Vec<EmbRec>>(&buf) {
        Ok(v) => v,
        Err(_) => {
            // Fallback: decode the entire buffer as a MessagePack array of maps
            // and extract `vector` or `embedding` fields (embed_runner uses `embedding`).
            let vals: Vec<JsonValue> = match from_slice(&buf) {
                Ok(v) => v,
                Err(e) => {
                    return Err(anyhow::anyhow!(e).context("deserializing generic msgpack array"))
                }
            };
            let mut items: Vec<EmbRec> = Vec::new();
            for val in vals {
                let id = val
                    .get("id")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                let vec_opt = val.get("vector").or_else(|| val.get("embedding"));
                if let Some(arr) = vec_opt.and_then(|x| x.as_array()) {
                    let vec_f: Vec<f32> = arr.iter().map(|n| n.as_f64().unwrap() as f32).collect();
                    items.push(EmbRec { id, vector: vec_f });
                }
            }
            items
        }
    };
    if vecs.is_empty() {
        anyhow::bail!("no vectors found")
    }
    let dim = vecs[0].vector.len();

    // Load chunk metadata (id -> path, idiom_weight)
    let chunks_buf = fs::read(chunks_path).context("read chunks")?;
    let chunks: Vec<JsonValue> = from_slice(&chunks_buf).context("deserialize chunks")?;
    let mut id_to_path: HashMap<String, String> = HashMap::new();
    let mut id_to_weight: HashMap<String, i32> = HashMap::new();
    for c in chunks {
        if let Some(id) = c.get("id").and_then(|v| v.as_str()) {
            if let Some(p) = c.get("path").and_then(|v| v.as_str()) {
                id_to_path.insert(id.to_string(), p.to_string());
            }
            let w = c
                .get("taxonomy")
                .and_then(|t| t.get("idiom_weight"))
                .and_then(|x| x.as_i64())
                .map(|n| n as i32)
                .unwrap_or(0);
            id_to_weight.insert(id.to_string(), w);
        }
    }

    // Build flat index using faiss via the python faiss binary? We'll use faiss-rs if available,
    // but to avoid adding new deps we will call Python's faiss if installed. If not present,
    // write a simple brute-force search in Rust for verification.

    // For portability, save vectors + metadata as a simple JSON + raw flat binary
    let mut ids: Vec<String> = Vec::new();
    let mut flat: Vec<f32> = Vec::with_capacity(vecs.len() * dim);
    let mut paths: Vec<String> = Vec::with_capacity(vecs.len());
    let mut weights: Vec<i32> = Vec::with_capacity(vecs.len());
    for e in &vecs {
        ids.push(e.id.clone());
        flat.extend_from_slice(&e.vector);
        paths.push(
            id_to_path
                .get(&e.id)
                .cloned()
                .unwrap_or_else(|| "<unknown>".to_string()),
        );
        weights.push(*id_to_weight.get(&e.id).unwrap_or(&0));
    }

    // FAISS support removed: fallback writes a raw JSON index file (portable, Rust-only)
    // Fallback: write out a raw JSON index file
    let index = serde_json::json!({"dim": dim, "ids": ids, "paths": paths, "weights": weights, "vectors": flat});
    fs::write(out_index, serde_json::to_vec(&index)?).context("write index")?;
    println!(
        "wrote index to {} (dim={}, count={})",
        out_index,
        dim,
        vecs.len()
    );
    Ok(())
}

// Simple brute-force search (dot product since vectors are normalized) over the JSON index
fn query_index(index_path: &str, q: &str, topk: usize) -> anyhow::Result<()> {
    let idx_data = fs::read(index_path).context("read index")?;
    let v: serde_json::Value = serde_json::from_slice(&idx_data)?;
    let dim = v["dim"].as_u64().unwrap() as usize;
    let ids = v["ids"].as_array().unwrap();
    let paths = v["paths"].as_array().unwrap();
    let weights = v["weights"].as_array().unwrap();
    let flat = v["vectors"].as_array().unwrap();
    let vectors: Vec<f32> = flat.iter().map(|x| x.as_f64().unwrap() as f32).collect();

    // embed query
    let mut model =
        TextEmbedding::try_new(InitOptions::default().with_show_download_progress(false))?;
    let qv = model.embed(vec![q.to_string()], None)?;
    let qv = &qv[0];
    // L2-normalize query
    let norm: f32 = qv.iter().map(|x| x * x).sum::<f32>().sqrt();
    let qnorm: Vec<f32> = if norm > 0.0 {
        qv.iter().map(|x| x / norm).collect()
    } else {
        qv.clone()
    };

    // Parallel brute-force dot product + idiom_weight reranking using Rayon
    // FinalScore = dot + (idiom_weight * 0.05)
    let n = ids.len();
    let mut scored: Vec<(usize, f32, f32, i32)> = (0..n)
        .into_par_iter()
        .map(|i| {
            let start = i * dim;
            let slice = &vectors[start..start + dim];
            let dot: f32 = slice.iter().zip(qnorm.iter()).map(|(a, b)| a * b).sum();
            let w = weights
                .get(i)
                .and_then(|x| x.as_i64())
                .map(|n| n as i32)
                .unwrap_or(0);
            let final_score = dot + (w as f32) * 0.05f32;
            (i, dot, final_score, w)
        })
        .collect();
    scored.par_sort_unstable_by(|a, b| b.2.partial_cmp(&a.2).unwrap());
    println!("Top {} results for query: {}", topk, q);
    for (i, dot, final_score, w) in scored.into_iter().take(topk) {
        let id = ids[i].as_str().unwrap();
        let path = paths.get(i).and_then(|p| p.as_str()).unwrap_or("<unknown>");
        println!(
            "final={:.4} dot={:.4} weight={} id={} path={}",
            final_score, dot, w, id, path
        );
    }
    Ok(())
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: flat_index <build|query> [...args]");
        std::process::exit(2);
    }
    match args[1].as_str() {
        "build" => {
            if args.len() != 5 {
                eprintln!("Usage: flat_index build <vectors.msgpack> <chunks.msgpack> <out.json>");
                std::process::exit(2);
            }
            build_index(&args[2], &args[3], &args[4])?
        }
        "query" => {
            if args.len() != 5 {
                eprintln!("Usage: flat_index query <index.json> <topk> <query_string>");
                std::process::exit(2);
            }
            let topk: usize = args[3].parse().unwrap_or(5);
            query_index(&args[2], &args[4], topk)?;
        }
        "inspect_ids" => {
            if args.len() < 3 {
                eprintln!("Usage: flat_index inspect_ids <index.json> <id> [id...]");
                std::process::exit(2);
            }
            let idx_data = fs::read(&args[2]).context("read index")?;
            let v: serde_json::Value = serde_json::from_slice(&idx_data)?;
            let ids = v["ids"].as_array().unwrap();
            let paths = v["paths"].as_array().unwrap();
            let weights = v["weights"].as_array().unwrap();
            for q in args.iter().skip(3) {
                for (i, idv) in ids.iter().enumerate() {
                    if idv.as_str().unwrap() == q {
                        println!(
                            "{} {} {}",
                            q,
                            paths[i].as_str().unwrap(),
                            weights[i].as_i64().unwrap()
                        );
                    }
                }
            }
        }
        _ => {
            eprintln!("unknown command");
        }
    }
    Ok(())
}
