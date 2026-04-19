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
        let input = tmp.path().join("input.jsonl");
        let output = tmp.path().join("out.jsonl");

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

        // write input
        {
            let file = File::create(&input).unwrap();
            use std::io::Write;
            for r in &recs {
                writeln!(&file, "{}", serde_json::to_string(r).unwrap()).unwrap();
            }
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
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(lines.len(), 2);
    }
}
