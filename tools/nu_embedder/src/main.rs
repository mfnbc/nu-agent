use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{Read, Write};

// Remote embedding helper
fn remote_embed_texts(inputs: &[String]) -> anyhow::Result<Vec<Vec<f32>>> {
    let default_url = "http://172.19.224.1:1234/v1/embeddings";
    let default_model = "text-embedding-mxbai-embed-large-v1";
    let url = std::env::var("EMBEDDING_REMOTE_URL").unwrap_or_else(|_| default_url.to_string());
    let api_key = std::env::var("EMBEDDING_API_KEY").ok();
    let model = std::env::var("EMBEDDING_MODEL").unwrap_or_else(|_| default_model.to_string());
    let client = reqwest::blocking::Client::new();
    let body = serde_json::json!({ "model": model, "input": inputs });
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
    // parse embeddings
    if let Some(e) = v.get("embeddings") {
        let parsed: Vec<Vec<f32>> = serde_json::from_value(e.clone())?;
        return Ok(parsed);
    }
    if let Some(data) = v.get("data") {
        let arr = data
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("unexpected data field"))?;
        let mut out = Vec::with_capacity(arr.len());
        for item in arr {
            if let Some(emb) = item.get("embedding") {
                let vecf: Vec<f32> = serde_json::from_value(emb.clone())?;
                out.push(vecf);
            } else {
                anyhow::bail!("unexpected data item shape")
            }
        }
        return Ok(out);
    }
    if v.is_array() {
        let parsed: Vec<Vec<f32>> = serde_json::from_value(v)?;
        return Ok(parsed);
    }
    anyhow::bail!("unexpected remote embedding response: {}", text)
}

#[derive(Deserialize)]
struct EmbIn {
    id: String,
    text: String,
}

#[derive(Serialize)]
struct EmbOut {
    id: String,
    vector: Vec<f32>,
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: nu_embedder <in.msgpack> <out.nuon>");
        std::process::exit(2);
    }

    let in_path = &args[1];
    let out_path = &args[2];
    // Optional third arg: limit number of records to embed (smoke test)
    let limit: Option<usize> = if args.len() > 3 {
        match args[3].parse::<usize>() {
            Ok(n) => Some(n),
            Err(_) => {
                eprintln!("invalid limit '{}', ignoring", args[3]);
                None
            }
        }
    } else {
        None
    };

    // Read input msgpack
    let mut file = File::open(in_path).context("opening input msgpack")?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).context("reading input file")?;
    // Deserialize input into a flexible serde_json::Value first so we can handle
    // either a single array value or a stream/other shapes produced by the
    // ingestion pipeline.
    // Try to decode as a MessagePack array of serde_json::Value first.
    // If that fails, fall back to streaming-deserializing multiple Value items
    // from the buffer using rmp_serde::Deserializer and collecting until EOF.
    let items: Vec<serde_json::Value> = match rmp_serde::from_slice::<Vec<serde_json::Value>>(&buf)
    {
        Ok(v) => v,
        Err(_) => {
            let mut items = Vec::new();
            let mut de = rmp_serde::Deserializer::new(&buf[..]);
            loop {
                match serde_json::Value::deserialize(&mut de) {
                    Ok(val) => items.push(val),
                    Err(e) => {
                        // If we've reached EOF (io error from rmp_serde), break;
                        // otherwise return the error.
                        let msg = format!("stream decode error: {}", e);
                        if msg.contains("EOF") || msg.contains("eof") {
                            break;
                        } else {
                            return Err(anyhow::anyhow!(e)
                                .context("deserializing input msgpack to serde_json::Value"));
                        }
                    }
                }
            }
            items
        }
    };

    // Normalize items into our simple EmbIn structs with best-effort field extraction.
    let mut docs: Vec<EmbIn> = Vec::with_capacity(items.len());
    for (i, item) in items.into_iter().enumerate() {
        let id = item
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| format!("generated-{}", i));
        let text = item
            .get("text")
            .and_then(|v| v.as_str())
            .or_else(|| item.get("embedding_input").and_then(|v| v.as_str()))
            .map(|s| s.to_string())
            .unwrap_or_default();
        docs.push(EmbIn { id, text });
    }

    // Use remote embedding service

    // Optionally limit docs for a smoke test
    let docs_to_process: Vec<EmbIn> = match limit {
        Some(n) => docs.into_iter().take(n).collect(),
        None => docs,
    };

    // Stream/process docs in batches to avoid OOM. We'll write incremental
    // MessagePack arrays to the output file by first writing an array header
    // and then appending each serialized named map element. This keeps memory
    // usage bounded to one batch of embeddings at a time.
    let batch_size: usize = 256;

    // Open output file for writing
    let mut out_file = File::create(out_path).context("creating output file")?;
    let write_json = out_path.ends_with(".json");

    // We'll write a MessagePack array header with the total length if we know
    // it up-front; otherwise we can write a stream of maps. For simplicity
    // we will serialize as a top-level array: write the full array by
    // collecting per-batch serialized items into the file. To avoid keeping
    // everything in memory, we'll write each serialized element and rely on
    // rmp format for concatenated maps being a valid stream. Consumers that
    // expect a single array can still decode a stream of maps; if needed we
    // can write a proper array header + elements, but that requires knowing
    // sizes ahead or rewriting the header later. This approach matches the
    // previous output (a sequence of named maps) and is resilient.

    // Process in batches
    let mut total_written: usize = 0;

    for chunk in docs_to_process.chunks(batch_size) {
        let texts: Vec<String> = chunk.iter().map(|d| d.text.clone()).collect();
        let emb_vectors = remote_embed_texts(&texts)?;

        for (i, v) in emb_vectors.into_iter().enumerate() {
            // L2-normalize vector
            let mut vec_f = v;
            let norm: f32 = vec_f.iter().map(|x| x * x).sum::<f32>().sqrt();
            if norm > 0.0 {
                for x in vec_f.iter_mut() {
                    *x /= norm;
                }
            }
            let out = EmbOut {
                id: chunk[i].id.clone(),
                vector: vec_f,
            };
            // serialize as named map and append to file
            if write_json {
                let j = serde_json::json!({"id": out.id, "vector": out.vector});
                out_file
                    .write_all(serde_json::to_string(&j)?.as_bytes())
                    .context("writing json line")?;
                out_file.write_all(b"\n")?;
            } else {
                let buf = rmp_serde::to_vec_named(&out).context("serializing output to msgpack")?;
                out_file
                    .write_all(&buf)
                    .context("writing serialized embedding to output file")?;
            }
            total_written += 1;
        }
    }

    println!("wrote {} embeddings to {}", total_written, out_path);
    Ok(())
}
