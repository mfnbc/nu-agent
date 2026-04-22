//! nu_plugin_rag library
//! Minimal helpers for manifest and embedding IO used by the nu_plugin binary.

// Re-export common helpers from nu_agent_common to keep the plugin surface small.
pub use nu_agent_common::{
    deterministic_embed, read_embedding_input, write_embeddings, DocRecord, EmbeddingOut,
    EmbeddingRecord,
};

use std::process::Command;

/// Run a command and capture its stdout; returns stderr on failure.
pub fn run_command_capture(cmd: &str, args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new(cmd).args(args).output()?;

    if output.status.success() {
        let s = String::from_utf8_lossy(&output.stdout).to_string();
        Ok(s)
    } else {
        let e = String::from_utf8_lossy(&output.stderr).to_string();
        anyhow::bail!("Command failed: {} {}: {}", cmd, args.join(" "), e)
    }
}

/// Download a URL to the destination path and return Ok(()) on success.
pub fn download_to_path(url: &str, dest: &std::path::Path) -> anyhow::Result<()> {
    let resp = reqwest::blocking::get(url)?;
    if !resp.status().is_success() {
        anyhow::bail!("Download failed: {} -> HTTP {}", url, resp.status());
    }

    let bytes = resp.bytes()?;
    std::fs::write(dest, &bytes)?;
    Ok(())
}

/// Compute blake3 hex digest of a file
pub fn blake3_of_file(path: &std::path::Path) -> anyhow::Result<String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

/// Embed the given input file and write outputs. This extracts the core logic
/// previously present in the embed_runner binary so callers (including tests)
/// can invoke it directly.
pub fn embed_and_write(input: &str, output: &str, vector_out: Option<&str>) -> anyhow::Result<()> {
    // Embeddings are produced via the configured remote embedding service. The
    // repository no longer contains a local native embedding binary fallback.
    // The remote path is used elsewhere in this file to call the service.
    use serde_json::Value;
    use std::fs;

    // Read corpus
    let mut chunks: Vec<Value> = Vec::new();
    if input.to_lowercase().ends_with(".nuon") {
        let s = fs::read_to_string(input)?;
        chunks = serde_json::from_str(&s)?;
    } else if input.to_lowercase().ends_with(".msgpack") {
        let recs = read_embedding_input(input)?;
        for r in recs {
            let mut m = serde_json::Map::new();
            m.insert("id".to_string(), Value::String(r.id));
            m.insert("embedding_input".to_string(), Value::String(r.text));
            chunks.push(Value::Object(m));
        }
    } else {
        anyhow::bail!(
            "unsupported input format: {} (supported: .nuon, .msgpack)",
            input
        );
    }

    // Remote-only embedding: require EMBEDDING_REMOTE_URL to be set. This keeps the
    // runtime surface simple and avoids loading any native ONNX runtime dependencies.

    // Collect texts in order so we can batch to whichever backend is configured.
    let texts: Vec<String> = chunks
        .iter()
        .map(|chunk| {
            chunk
                .get("embedding_input")
                .or_else(|| chunk.get("text"))
                .or_else(|| chunk.get("data"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_default()
        })
        .collect();

    // Embeddings are remote-only by default. The remote service is configured via
    // EMBEDDING_REMOTE_URL / EMBEDDING_MODEL / EMBEDDING_API_KEY. A deterministic
    // fallback is available for tests.
    fn parse_embeddings_from_value(v: serde_json::Value) -> Option<Vec<Vec<f32>>> {
        // Try { "embeddings": [[...], ...] }
        if let Some(e) = v.get("embeddings") {
            if e.is_array() {
                let parsed: Result<Vec<Vec<f32>>, _> = serde_json::from_value(e.clone());
                if let Ok(p) = parsed {
                    return Some(p);
                }
            }
        }

        // Try { "data": [{"embedding": [...]}, ...] }
        if let Some(data) = v.get("data") {
            if let Some(arr) = data.as_array() {
                let mut out = Vec::with_capacity(arr.len());
                for item in arr {
                    if let Some(emb) = item.get("embedding") {
                        if let Ok(vecf) = serde_json::from_value::<Vec<f32>>(emb.clone()) {
                            out.push(vecf);
                            continue;
                        }
                    }
                    // Some APIs return embedding under "vector" or different key
                    if let Some(emb) = item.get("vector") {
                        if let Ok(vecf) = serde_json::from_value::<Vec<f32>>(emb.clone()) {
                            out.push(vecf);
                            continue;
                        }
                    }
                    return None;
                }
                return Some(out);
            }
        }

        // Try array-of-arrays at top level
        if v.is_array() {
            if let Ok(parsed) = serde_json::from_value::<Vec<Vec<f32>>>(v) {
                return Some(parsed);
            }
        }

        None
    }

    // Performs a blocking POST to a remote embedding service. The service is expected
    // to accept JSON { "model": "...", "inputs": ["text1", ...] } and return either
    // { "embeddings": [[...], ...] } or { "data": [{"embedding": [...]}, ...] }
    fn remote_embed(
        url: &str,
        api_key: Option<String>,
        inputs: &[String],
        model: &str,
    ) -> anyhow::Result<Vec<Vec<f32>>> {
        use std::thread::sleep;
        use std::time::Duration;

        let timeout_ms: u64 = std::env::var("EMBEDDING_REQUEST_TIMEOUT_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(10_000);
        let retries: usize = std::env::var("EMBEDDING_REQUEST_RETRIES")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(3);

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_millis(timeout_ms))
            .build()?;
        let body = serde_json::json!({ "model": model, "input": inputs });
        // Avoid relying on reqwest's `json` helper in case the feature set differs;
        // send a JSON body explicitly.
        let body_str = serde_json::to_string(&body)?;

        let mut last_err: Option<anyhow::Error> = None;
        let mut v: serde_json::Value = serde_json::Value::Null;
        for attempt in 0..retries {
            let mut req = client
                .post(url)
                .header("Content-Type", "application/json")
                .body(body_str.clone());
            if let Some(k) = api_key.clone() {
                req = req.header("Authorization", format!("Bearer {}", k));
            }
            match req.send() {
                Ok(resp) => {
                    let status = resp.status();
                    match resp.text() {
                        Ok(text) => {
                            if !status.is_success() {
                                if status.is_server_error() && attempt + 1 < retries {
                                    last_err = Some(anyhow::anyhow!(
                                        "remote embedding request failed (status {}): {}",
                                        status,
                                        text
                                    ));
                                    sleep(Duration::from_millis(250 * 2u64.pow(attempt as u32)));
                                    continue;
                                }
                                anyhow::bail!(
                                    "remote embedding request failed: {}: {}",
                                    status,
                                    text
                                );
                            }
                            v = serde_json::from_str(&text)?;
                            break;
                        }
                        Err(e) => last_err = Some(anyhow::anyhow!(e)),
                    }
                }
                Err(e) => last_err = Some(anyhow::anyhow!(e)),
            }
            if attempt + 1 < retries {
                sleep(Duration::from_millis(250 * 2u64.pow(attempt as u32)));
            }
        }
        if v.is_null() {
            if let Some(e) = last_err {
                return Err(e);
            }
            anyhow::bail!("remote embedding request failed: unknown error");
        }
        if let Some(embs) = parse_embeddings_from_value(v.clone()) {
            if embs.len() != inputs.len() {
                anyhow::bail!(
                    "remote embedding service returned {} embeddings for {} inputs",
                    embs.len(),
                    inputs.len()
                );
            }
            return Ok(embs);
        }
        anyhow::bail!("unexpected remote embedding response: {:?}", v)
    }

    // Default: use local service at 172.19.224.1:1234 with MXBAI embedding model.
    let default_url = "http://172.19.224.1:1234/v1/embeddings";
    let default_model = "text-embedding-mxbai-embed-large-v1";

    let url = std::env::var("EMBEDDING_REMOTE_URL").unwrap_or_else(|_| default_url.to_string());
    let api_key = std::env::var("EMBEDDING_API_KEY").ok();
    let model = std::env::var("EMBEDDING_MODEL").unwrap_or_else(|_| default_model.to_string());
    let embeddings_all: Vec<Vec<f32>> = remote_embed(&url, api_key, &texts, &model)?;

    let mut produced = Vec::with_capacity(chunks.len());
    for (idx, chunk) in chunks.iter().enumerate() {
        let id = chunk
            .get("id")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let path = chunk
            .get("path")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_default();
        let title = chunk
            .get("title")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_default();
        let heading_path = chunk.get("heading_path").cloned().unwrap_or(Value::Null);

        let text = texts.get(idx).cloned().unwrap_or_default();
        let embedding = embeddings_all.get(idx).cloned().unwrap_or_default();

        let mut obj = serde_json::Map::new();
        obj.insert("id".to_string(), Value::String(id.clone()));
        obj.insert("path".to_string(), Value::String(path));
        obj.insert("title".to_string(), Value::String(title));
        obj.insert("heading_path".to_string(), heading_path);
        obj.insert("text".to_string(), Value::String(text.clone()));
        obj.insert("embedding".to_string(), serde_json::to_value(&embedding)?);

        let mut meta = serde_json::Map::new();
        meta.insert(
            "path".to_string(),
            chunk
                .get("path")
                .cloned()
                .unwrap_or(Value::String("".into())),
        );
        meta.insert(
            "title".to_string(),
            chunk
                .get("title")
                .cloned()
                .unwrap_or(Value::String("".into())),
        );
        meta.insert(
            "heading_path".to_string(),
            chunk.get("heading_path").cloned().unwrap_or(Value::Null),
        );

        let rec = serde_json::json!({"id": id.clone(), "text": text.clone(), "embedding": embedding, "metadata": Value::Object(meta)});
        produced.push(rec);
    }

    if let Some(vo) = vector_out {
        if !produced.is_empty() {
            if let Some(emb) = produced[0].get("embedding") {
                let vec_f: Vec<f32> = serde_json::from_value(emb.clone())?;
                let mut buf_v = Vec::new();
                rmp_serde::encode::write(&mut buf_v, &vec_f)?;
                std::fs::write(vo, buf_v)?;
            }
        }
    }

    if let Some(p) = std::path::Path::new(output).parent() {
        std::fs::create_dir_all(p)?;
    }
    let mut buf = Vec::new();
    rmp_serde::encode::write(&mut buf, &produced)?;
    std::fs::write(output, buf)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    #[test]
    fn test_deterministic_embed_len() {
        let v = deterministic_embed("hello world", 8);
        assert_eq!(v.len(), 8);
    }

    #[test]
    fn test_read_write_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let input = tmp.path().join("input.nuon");
        let output = tmp.path().join("out.nuon");

        let recs = vec![
            EmbeddingRecord {
                id: "1".to_string(),
                text: "a".to_string(),
            },
            EmbeddingRecord {
                id: "2".to_string(),
                text: "b".to_string(),
            },
        ];

        // write input as a NUON JSON array
        {
            let file = File::create(&input).unwrap();
            use std::io::Write;
            writeln!(&file, "{}", serde_json::to_string_pretty(&recs).unwrap()).unwrap();
        }

        let read = read_embedding_input(&input).unwrap();
        assert_eq!(read.len(), 2);

        let embeddings: Vec<EmbeddingOut> = read
            .iter()
            .map(|r| EmbeddingOut {
                id: r.id.clone(),
                embedding: deterministic_embed(&r.text, 16),
            })
            .collect();

        write_embeddings(&output, &embeddings).unwrap();

        let s = std::fs::read_to_string(&output).unwrap();
        let parsed: Vec<EmbeddingOut> = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed.len(), 2);
    }
}
