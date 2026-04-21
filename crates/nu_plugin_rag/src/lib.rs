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
    use fastembed::TextEmbedding;
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

    let mut model = TextEmbedding::try_new(Default::default())?;

    let mut produced = Vec::with_capacity(chunks.len());
    for chunk in chunks.iter() {
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
        let text = chunk
            .get("embedding_input")
            .or_else(|| chunk.get("text"))
            .or_else(|| chunk.get("data"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_default();

        let embeddings = model.embed(vec![text.clone()], None)?;
        let embedding = embeddings.into_iter().next().unwrap_or_default();

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
