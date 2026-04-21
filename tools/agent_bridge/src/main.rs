use anyhow::Context;
use fastembed::{InitOptions, TextEmbedding};
use rayon::prelude::*;
use rmp_serde::from_slice;
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use std::fs;

#[derive(Debug)]
struct Chunk {
    id: String,
    path: String,
    text: String,
}

fn extract_text_from_value(c: &JsonValue) -> String {
    if let Some(s) = c.get("text").and_then(|v| v.as_str()) {
        return s.to_string();
    }
    if let Some(s) = c.get("content").and_then(|v| v.as_str()) {
        return s.to_string();
    }
    if let Some(s) = c.get("body").and_then(|v| v.as_str()) {
        return s.to_string();
    }
    if let Some(s) = c.get("code").and_then(|v| v.as_str()) {
        return s.to_string();
    }
    if let Some(arr) = c.get("examples").and_then(|v| v.as_array()) {
        let mut acc = String::new();
        for ex in arr {
            if let Some(s) = ex.as_str() {
                acc.push_str(s);
                acc.push('\n');
            } else {
                acc.push_str(&serde_json::to_string(ex).unwrap_or_default());
                acc.push('\n');
            }
        }
        if !acc.is_empty() {
            return acc;
        }
    }
    serde_json::to_string(c).unwrap_or_default()
}

fn load_chunks(path: &str) -> anyhow::Result<Vec<Chunk>> {
    let buf = fs::read(path).context("read chunks.msgpack")?;
    let v: Vec<JsonValue> = from_slice(&buf).context("deserialize chunks.msgpack")?;
    let mut chunks: Vec<Chunk> = Vec::with_capacity(v.len());
    for c in v {
        let id = c
            .get("id")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let path = c
            .get("path")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let text = extract_text_from_value(&c);
        chunks.push(Chunk { id, path, text });
    }
    Ok(chunks)
}

fn build_index_map(chunks: &[Chunk]) -> HashMap<String, usize> {
    let mut m = HashMap::new();
    for (i, c) in chunks.iter().enumerate() {
        m.insert(c.id.clone(), i);
    }
    m
}

fn format_prompt(user_query: &str, top: &[(String, f32, f32, i32, String)]) -> String {
    let mut out = String::new();
    out.push_str("### CONTEXT: IDIOMATIC NUSHELL EXAMPLES\n");
    out.push_str("Below are verified examples from the Nushell documentation.\n");
    out.push_str(
        "Items with \"Weight: 3\" are considered \"Gold Standard\" idiomatic patterns.\n\n",
    );
    for (i, (id, dot, final_score, weight, path)) in top.iter().enumerate() {
        out.push_str(&format!(
            "[Example {}] (Weight: {}, Path: {})\n",
            i + 1,
            weight,
            path
        ));
        out.push_str(&format!(
            "Score: dot={:.4} final={:.4} id={}\n",
            dot, final_score, id
        ));
        out.push_str("---\n");
    }
    out.push_str("\n### TASK\n");
    out.push_str(&format!("User Request: \"{}\"\n", user_query));
    out.push_str("Instruction: Synthesize a solution using the patterns above. Favor the pipeline-centric approach (Weight 3) over imperative loops. Use code with caution.\n");
    out
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    // Usage: agent_bridge [--json] "query"
    if args.len() < 2 {
        eprintln!("Usage: agent_bridge [--json] <query>");
        std::process::exit(2);
    }
    let mut json_out = false;
    let mut _query = String::new();
    if args.len() == 2 {
        query = args[1].clone();
    } else {
        // support: agent_bridge --json "query"
        if args[1] == "--json" || args[1] == "-j" {
            json_out = true;
            _query = args[2].clone();
        } else {
            // join remaining args as the query (allow unquoted)
            _query = args[1..].join(" ");
        }
    }

    // load index JSON produced earlier
    let idx_data = fs::read("data/nu_idioms.index").context("read index JSON")?;
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
    let qv = model.embed(vec![_query.to_string()], None)?;
    let qv = &qv[0];
    let norm: f32 = qv.iter().map(|x| x * x).sum::<f32>().sqrt();
    let qnorm: Vec<f32> = if norm > 0.0 {
        qv.iter().map(|x| x / norm).collect()
    } else {
        qv.clone()
    };

    // parallel scan
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

    // load chunks.msgpack and build map
    let chunks = load_chunks("build/nu_ingest/chunks.msgpack")?;
    let id_map = build_index_map(&chunks);

    // assemble top-3 details and include truncated chunk text
    #[derive(serde::Serialize)]
    struct TopEntry {
        id: String,
        path: String,
        weight: i32,
        dot: f32,
        final_score: f32,
        text: String,
    }

    let mut top_entries: Vec<TopEntry> = Vec::new();
    for (i, dot, final_score, w) in scored.into_iter().take(3) {
        let id = ids[i].as_str().unwrap().to_string();
        let path = paths
            .get(i)
            .and_then(|p| p.as_str())
            .unwrap_or("<unknown>")
            .to_string();
        // lookup chunk text by id
        let mut body = "<missing>".to_string();
        if let Some(idx) = id_map.get(&id) {
            body = chunks[*idx].text.clone();
        }
        // truncate to 1500 characters (preserve UTF-8 boundaries)
        let truncated = if body.chars().count() > 1500 {
            let s: String = body.chars().take(1500).collect();
            format!("{}... [truncated]", s)
        } else {
            body.clone()
        };
        top_entries.push(TopEntry {
            id,
            path,
            weight: w,
            dot,
            final_score,
            text: truncated,
        });
    }

    if json_out {
        // Output minimal JSON suitable for programmatic consumption
        let out = serde_json::json!({
            "query": _query,
            "results": top_entries,
        });
        println!("{}", serde_json::to_string_pretty(&out)?);
        return Ok(());
    }

    // fallback: format human-readable prompt from top_entries
    let mut top_for_prompt: Vec<(String, f32, f32, i32, String)> = Vec::new();
    for e in &top_entries {
        top_for_prompt.push((
            e.id.to_string(),
            e.dot,
            e.final_score,
            e.weight,
            format!("{}\n{}", e.path, e.text),
        ));
    }
    let prompt = format_prompt(&query, &top_for_prompt);
    println!("{}", prompt);

    Ok(())
}
