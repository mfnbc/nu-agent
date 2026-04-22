use anyhow::Context;
use rayon::prelude::*;
use std::fs;

fn query_index(index_path: &str, q: &str, topk: usize) -> anyhow::Result<()> {
    let idx_data = fs::read(index_path).context("read index")?;
    let v: serde_json::Value = serde_json::from_slice(&idx_data)?;
    let dim = v["dim"].as_u64().unwrap() as usize;
    let ids = v["ids"].as_array().unwrap();
    let flat = v["vectors"].as_array().unwrap();
    let vectors: Vec<f32> = flat.iter().map(|x| x.as_f64().unwrap() as f32).collect();

    // embed query via remote embedding service
    let texts = vec![q.to_string()];
    let default_url = "http://172.19.224.1:1234/v1/embeddings";
    let default_model = "text-embedding-mxbai-embed-large-v1";
    let url = std::env::var("EMBEDDING_REMOTE_URL").unwrap_or_else(|_| default_url.to_string());
    let api_key = std::env::var("EMBEDDING_API_KEY").ok();
    let model_name = std::env::var("EMBEDDING_MODEL").unwrap_or_else(|_| default_model.to_string());
    let client = reqwest::blocking::Client::new();
    let body = serde_json::json!({ "model": model_name, "input": texts });
    let body_str = serde_json::to_string(&body)?;
    let mut req = client
        .post(&url)
        .header("Content-Type", "application/json")
        .body(body_str);
    if let Some(k) = api_key {
        req = req.header("Authorization", format!("Bearer {}", k));
    }
    let resp = req.send()?;
    let status = resp.status();
    let text = resp.text()?;
    if !status.is_success() {
        anyhow::bail!("remote embedding request failed: {}: {}", status, text);
    }
    let v: serde_json::Value = serde_json::from_str(&text)?;
    let qv = if let Some(e) = v.get("embeddings") {
        let parsed: Vec<Vec<f32>> = serde_json::from_value(e.clone())?;
        parsed[0].clone()
    } else if let Some(data) = v.get("data") {
        let arr = data
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("unexpected data field"))?;
        if let Some(emb) = arr[0].get("embedding") {
            serde_json::from_value(emb.clone())?
        } else {
            anyhow::bail!("unexpected data item shape")
        }
    } else if v.is_array() {
        let parsed: Vec<Vec<f32>> = serde_json::from_value(v)?;
        parsed[0].clone()
    } else {
        anyhow::bail!("unexpected remote embedding response: {}", text)
    };

    // L2-normalize query
    let norm: f32 = qv.iter().map(|x| x * x).sum::<f32>().sqrt();
    let qnorm: Vec<f32> = if norm > 0.0 {
        qv.iter().map(|x| x / norm).collect()
    } else {
        qv.clone()
    };

    let n = ids.len();
    let mut scored: Vec<(usize, f32)> = (0..n)
        .into_par_iter()
        .map(|i| {
            let start = i * dim;
            let slice = &vectors[start..start + dim];
            let dot: f32 = slice.iter().zip(qnorm.iter()).map(|(a, b)| a * b).sum();
            (i, dot)
        })
        .collect();
    scored.par_sort_unstable_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("Top {} results for query: {}", topk, q);
    for (i, dot) in scored.into_iter().take(topk) {
        let id = ids[i].as_str().unwrap().to_string();
        println!("dot={:.4} id={}", dot, id);
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
        "query" => {
            if args.len() != 5 {
                eprintln!("Usage: flat_index query <index.json> <topk> <query_string>");
                std::process::exit(2);
            }
            let topk: usize = args[3].parse().unwrap_or(5);
            query_index(&args[2], &args[4], topk)?;
        }
        _ => {
            eprintln!("unknown command");
        }
    }
    Ok(())
}
