use anyhow::Context;
use blake3;
use rmp_serde::to_vec_named;
use rmp_serde::Deserializer;
use serde::Deserialize;
use serde_json::Value as JsonValue;
use std::io::{self, Read, Write};

// MapRec was a small helper used in older tooling; remove to reduce build warnings.

fn parse_msgpack_stream(buf: &[u8]) -> Vec<serde_json::Map<String, JsonValue>> {
    let mut de = Deserializer::new(&buf[..]);
    let mut items = Vec::new();
    loop {
        match serde_json::Value::deserialize(&mut de) {
            Ok(v) => match v {
                JsonValue::Object(m) => items.push(m),
                _ => continue,
            },
            Err(_) => break,
        }
    }
    items
}

fn parse_ndjson(text: &str) -> Vec<serde_json::Map<String, JsonValue>> {
    let mut out = Vec::new();
    for line in text.lines() {
        let s = line.trim();
        if s.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<JsonValue>(s) {
            if let JsonValue::Object(m) = v {
                out.push(m);
            }
        }
    }
    out
}

fn deterministic_embedding_from_text(text: &str, dim: usize) -> Vec<f32> {
    // Use blake3 hash to produce deterministic bytes and turn into floats.
    let hash = blake3::hash(text.as_bytes());
    let bytes = hash.as_bytes();
    let mut out = Vec::with_capacity(dim);
    // Expand bytes if needed by hashing successive counters
    let mut i = 0u32;
    while out.len() < dim {
        let mut hasher = blake3::Hasher::new();
        hasher.update(bytes);
        hasher.update(&i.to_le_bytes());
        let h = hasher.finalize();
        let hb = h.as_bytes();
        for chunk in hb.chunks(4) {
            if out.len() >= dim {
                break;
            }
            // convert 4 bytes to u32 then to f32 in [-1,1]
            let mut arr = [0u8; 4];
            for (j, b) in chunk.iter().enumerate() {
                arr[j] = *b;
            }
            let u = u32::from_le_bytes(arr);
            // map to float between -1 and 1
            let f = (u as f32 / std::u32::MAX as f32) * 2.0 - 1.0;
            out.push(f);
        }
        i += 1;
    }
    // L2-normalize
    let norm: f32 = out.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        out.iter_mut().for_each(|x| *x /= norm);
    }
    out
}

fn main() -> anyhow::Result<()> {
    // Simple CLI: support --batch-size N and --dim N and fallback to mock embeddings.
    let args: Vec<String> = std::env::args().collect();
    let mut batch_size: usize = 64;
    let mut dim: usize = 8;
    for i in 0..args.len() {
        if args[i] == "--batch-size" {
            if let Some(v) = args.get(i + 1) {
                batch_size = v.parse().unwrap_or(batch_size);
            }
        }
        if args[i] == "--dim" {
            if let Some(v) = args.get(i + 1) {
                dim = v.parse().unwrap_or(dim);
            }
        }
    }

    let mut stdin = String::new();
    io::stdin().read_to_string(&mut stdin)?;

    let mut records: Vec<serde_json::Map<String, JsonValue>> = Vec::new();
    let trimmed = stdin.trim();
    if trimmed.is_empty() {
        return Ok(());
    }

    // Heuristic: if first non-whitespace char is '{', treat as NDJSON/JSON lines or JSON array
    let first_char = trimmed.chars().next().unwrap_or('\0');
    if first_char == '{' || first_char == '[' {
        // Try JSON array first
        if let Ok(v) = serde_json::from_str::<JsonValue>(&stdin) {
            match v {
                JsonValue::Array(arr) => {
                    for it in arr.into_iter() {
                        if let JsonValue::Object(m) = it {
                            records.push(m);
                        }
                    }
                }
                JsonValue::Object(m) => records.push(m),
                _ => {}
            }
        } else {
            // fallback to NDJSON
            records = parse_ndjson(&stdin);
        }
    } else {
        // treat as msgpack stream
        let bytes = stdin.into_bytes();
        records = parse_msgpack_stream(&bytes);
    }

    let mut out = io::stdout();
    // Process in batches
    for chunk in records.chunks(batch_size) {
        // For mock mode, compute embeddings locally
        for rec in chunk {
            // determine text source: prefer embedding_input, then text, then content
            let text = rec
                .get("embedding_input")
                .or_else(|| rec.get("text"))
                .or_else(|| rec.get("content"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let emb = deterministic_embedding_from_text(text, dim);
            // build an output map by cloning and inserting embedding as Vec<f32>
            let mut out_map = rec.clone();
            // convert embedding Vec<f32> to JsonValue::Array of numbers for serializing via rmp
            let arr_vals: Vec<JsonValue> = emb.iter().map(|f| JsonValue::from(*f as f64)).collect();
            out_map.insert("embedding".to_string(), JsonValue::Array(arr_vals));
            let buf = to_vec_named(&out_map).context("serializing msgpack record")?;
            out.write_all(&buf)?;
        }
    }
    Ok(())
}
