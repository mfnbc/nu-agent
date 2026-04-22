use anyhow::Context;
use blake3;
use nu_plugin_rag::commands::embed::Embed;
use nu_protocol::{Span, Value};
use reqwest::blocking::Client;
use rmp_serde::to_vec_named;
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

fn chunk_text(text: &str, max_chars: usize, overlap: usize) -> Vec<String> {
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

#[derive(Clone, Serialize, serde::Deserialize)]
struct SavedDoc {
    id: String,
    vector: Vec<f32>,
    value: nu_protocol::Value,
}

#[derive(Clone, Serialize, serde::Deserialize)]
struct SavedBucket {
    dimension: Option<usize>,
    docs: Vec<SavedDoc>,
}

fn collect_md(root: &PathBuf) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        if let Ok(entries) = fs::read_dir(&dir) {
            for e in entries.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else if let Some(ext) = p.extension() {
                    if ext == "md" {
                        out.push(p);
                    }
                }
            }
        }
    }
    out
}

fn main() -> anyhow::Result<()> {
    const FLUSH_INTERVAL: usize = 500;
    const EMBED_BATCH: usize = 64;

    let cwd = std::env::current_dir()?;
    let root = cwd.join("external/nushell.github.io");
    if !root.exists() {
        anyhow::bail!("docs root not found: {}", root.display());
    }

    let files = collect_md(&root);
    eprintln!(
        "Found {} markdown files under {}",
        files.len(),
        root.display()
    );

    let client = Client::new();
    let embed_url = std::env::var("EMBEDDING_REMOTE_URL")
        .unwrap_or_else(|_| "http://172.19.224.1:1234/v1/embeddings".to_string());
    let embed_model = std::env::var("EMBEDDING_MODEL")
        .unwrap_or_else(|_| "text-embedding-mxbai-embed-large-v1".to_string());

    let partial_path = PathBuf::from("/tmp/partial_nu_wiki.msgpack");
    let mut saved_docs: Vec<SavedDoc> = Vec::new();
    let mut seen_ids: HashSet<String> = HashSet::new();
    let mut total_chunks = 0usize;
    let dim_default = 768usize;

    // Resume from partial if present
    if partial_path.exists() {
        match fs::read(&partial_path) {
            Ok(buf) => match rmp_serde::from_slice::<SavedBucket>(&buf) {
                Ok(sb) => {
                    eprintln!(
                        "Resuming: loaded {} existing docs from {}",
                        sb.docs.len(),
                        partial_path.display()
                    );
                    for d in sb.docs.into_iter() {
                        seen_ids.insert(d.id.clone());
                        total_chunks += 1;
                        saved_docs.push(d);
                    }
                }
                Err(e) => eprintln!("failed to parse partial file: {} - will start fresh", e),
            },
            Err(e) => eprintln!(
                "failed to read partial file {}: {}",
                partial_path.display(),
                e
            ),
        }
    }

    // Process files, embedding in batches and periodically flushing to partial file
    for p in files.iter() {
        match fs::read_to_string(p) {
            Ok(s) => {
                let chunks = chunk_text(&s, 1800, 200);
                // Build vector of (id, text) for chunks we still need
                let mut meta: Vec<(String, String)> = Vec::new();
                for c in chunks.into_iter() {
                    let id = blake3::hash(c.as_bytes()).to_hex().to_string();
                    if seen_ids.contains(&id) {
                        continue;
                    }
                    meta.push((id, c));
                }

                // process meta in EMBED_BATCH groups
                for chunk_slice in meta.chunks(EMBED_BATCH) {
                    let slice_vec: Vec<String> =
                        chunk_slice.iter().map(|(_, t)| t.clone()).collect();
                    let embeddings = match Embed::http_embed_texts(
                        &client,
                        &embed_url,
                        &embed_model,
                        &slice_vec,
                    ) {
                        Ok(v) => v,
                        Err(e) => {
                            eprintln!(
                                "embedding request failed for batch at file {}: {}",
                                p.display(),
                                e
                            );
                            // try to continue with next batch
                            continue;
                        }
                    };

                    for (i, emb) in embeddings.into_iter().enumerate() {
                        let (id, text_field) = &chunk_slice[i];
                        let mut rec = nu_protocol::Record::new();
                        rec.push("id".to_string(), Value::string(id.clone(), Span::unknown()));
                        rec.push(
                            "path".to_string(),
                            Value::string(p.to_string_lossy().to_string(), Span::unknown()),
                        );
                        rec.push(
                            "text".to_string(),
                            Value::string(text_field.clone(), Span::unknown()),
                        );

                        let sd = SavedDoc {
                            id: id.clone(),
                            vector: emb,
                            value: Value::Record {
                                val: Box::new(rec),
                                internal_span: Span::unknown(),
                            },
                        };
                        seen_ids.insert(id.clone());
                        saved_docs.push(sd);
                        total_chunks += 1;
                    }

                    if total_chunks % FLUSH_INTERVAL == 0 {
                        // flush partial
                        let dim = saved_docs
                            .get(0)
                            .map(|d| d.vector.len())
                            .unwrap_or(dim_default);
                        let sb = SavedBucket {
                            dimension: Some(dim),
                            docs: saved_docs.clone(),
                        };
                        match to_vec_named(&sb) {
                            Ok(buf) => {
                                if let Err(e) = fs::write(&partial_path, &buf) {
                                    eprintln!(
                                        "failed to write partial file {}: {}",
                                        partial_path.display(),
                                        e
                                    );
                                } else {
                                    eprintln!(
                                        "Flushed partial index with {} docs to {}",
                                        sb.docs.len(),
                                        partial_path.display()
                                    );
                                }
                            }
                            Err(e) => eprintln!("serialize partial failed: {}", e),
                        }
                    }

                    eprintln!("Processed {} chunks so far...", total_chunks);
                }
            }
            Err(e) => eprintln!("failed to read {}: {}", p.display(), e),
        }
    }

    if saved_docs.is_empty() {
        anyhow::bail!("no chunks were produced");
    }

    // final save to ./data/nu_wiki.msgpack and remove partial
    let dim = saved_docs
        .get(0)
        .map(|d| d.vector.len())
        .unwrap_or(dim_default);
    let sb = SavedBucket {
        dimension: Some(dim),
        docs: saved_docs.clone(),
    };
    let out_dir = PathBuf::from("./data");
    if !out_dir.exists() {
        fs::create_dir_all(&out_dir)?;
    }
    let out_path = out_dir.join("nu_wiki.msgpack");
    let buf = to_vec_named(&sb).context("serialize index to msgpack")?;
    fs::write(&out_path, &buf).context("write index file")?;

    eprintln!(
        "Saved final index with {} docs (dim {}) to {}",
        sb.docs.len(),
        dim,
        out_path.display()
    );
    if partial_path.exists() {
        let _ = fs::remove_file(&partial_path);
    }

    // Run a demo query now
    let query = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "How do I write a custom completion?".to_string());
    eprintln!("Running demo query: {}", query);
    let qembs = Embed::http_embed_texts(&client, &embed_url, &embed_model, &vec![query.clone()])?;
    let qv = qembs
        .into_iter()
        .next()
        .unwrap_or_else(|| vec![0.0f32; dim]);

    // load saved bucket to compute dot products
    let buf_in = fs::read(&out_path)?;
    let loaded: SavedBucket = rmp_serde::from_slice(&buf_in)?;
    let mut scores: Vec<(String, f32, nu_protocol::Value)> = loaded
        .docs
        .into_iter()
        .map(|d| {
            let score: f32 = d.vector.iter().zip(&qv).map(|(a, b)| a * b).sum();
            (d.id, score, d.value)
        })
        .collect();
    scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let topk = 5usize;
    eprintln!("Top {} hits:", topk);
    for (id, score, val) in scores.iter().take(topk) {
        let preview = match val {
            Value::Record { val, .. } => val
                .get("text")
                .and_then(|v| v.coerce_string().ok())
                .unwrap_or_else(|| "<no text>".to_string()),
            other => other
                .coerce_string()
                .unwrap_or_else(|_| "<non-string>".to_string()),
        };
        eprintln!(
            "{:.4}\t{}\n{}\n---",
            score,
            id,
            &preview[..std::cmp::min(200, preview.len())]
        );
    }

    // Hydrate top-3 and call chat completion
    let hydrate_k = 3usize;
    let mut context_pieces: Vec<String> = Vec::new();
    for (_, _, val) in scores.into_iter().take(hydrate_k) {
        let text = match val {
            Value::Record { val, .. } => val
                .get("text")
                .and_then(|v| v.coerce_string().ok())
                .unwrap_or_else(|| "".to_string()),
            other => other.coerce_string().unwrap_or_else(|_| "".to_string()),
        };
        context_pieces.push(text);
    }

    let prompt = format!(
        "Answer the user question using this context:\n\n{}\n\nQuestion: {}",
        context_pieces.join("\n\n"),
        query
    );

    // Call chat completion
    let chat_url = std::env::var("NU_AGENT_CHAT_URL")
        .unwrap_or_else(|_| "http://172.19.224.1:1234/v1/chat/completions".to_string());
    let chat_model =
        std::env::var("NU_AGENT_MODEL").unwrap_or_else(|_| "google/gemma-4-26b-a4b".to_string());

    let body = serde_json::json!({
        "model": chat_model,
        "messages": [{"role": "user", "content": prompt}],
    });
    let resp = client
        .post(&chat_url)
        .json(&body)
        .send()
        .context("chat request failed")?;
    let status = resp.status();
    let text = resp.text().unwrap_or_else(|_| "".to_string());
    if !status.is_success() {
        eprintln!("chat request failed {}: {}", status, text);
    } else {
        // try to parse typical shapes
        if let Ok(json_resp) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(content) = json_resp
                .get("choices")
                .and_then(|ch| ch.get(0))
                .and_then(|c| c.get("message"))
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
            {
                println!("LLM response:\n{}", content);
            } else if let Some(content) = json_resp
                .get("choices")
                .and_then(|ch| ch.get(0))
                .and_then(|c| c.get("text"))
                .and_then(|t| t.as_str())
            {
                println!("LLM response:\n{}", content);
            } else {
                println!("Chat response JSON (raw): {}", text);
            }
        } else {
            println!("Chat response (raw): {}", text);
        }
    }

    Ok(())
}
