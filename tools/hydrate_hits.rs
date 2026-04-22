use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;

#[derive(Deserialize)]
struct Hit {
    id: String,
    idx: usize,
    score: f32,
}

#[derive(Deserialize, Serialize, Debug)]
struct Doc {
    id: String,
    idx: usize,
    title: Option<String>,
    path: Option<String>,
    content: Option<String>,
    score: Option<f32>,
}

fn main() -> anyhow::Result<()> {
    let hits: Vec<Hit> = serde_json::from_str(&fs::read_to_string("build/rag/hits.json")?)?;
    let mut seen = HashSet::new();
    let mut top: Vec<Hit> = Vec::new();
    for h in hits {
        if !seen.contains(&h.id) {
            seen.insert(h.id.clone());
            top.push(h);
            if top.len() >= 5 {
                break;
            }
        }
    }

    // load documents msgpack
    let data = fs::read("data/nu_docs.msgpack")?;
    let mut deserializer = rmp_serde::Deserializer::new(&data[..]);
    let docs: Vec<serde_json::Value> = serde_path_to_error::deserialize(&mut deserializer)?;

    let mut out = Vec::new();
    for h in top {
        // find doc with matching id and idx
        for d in &docs {
            if d.get("id").and_then(|v| v.as_str()) == Some(&h.id)
                && d.get("idx").and_then(|v| v.as_u64()) == Some(h.idx as u64)
            {
                let title = d
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let path = d
                    .get("path")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let content = d
                    .get("content")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                out.push(serde_json::json!({"id": h.id, "idx": h.idx, "score": h.score, "title": title, "path": path, "content": content}));
                break;
            }
        }
    }

    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}
