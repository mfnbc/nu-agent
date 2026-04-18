use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct EmbeddingRecord {
    pub id: String,
    pub text: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct EmbeddingOut {
    pub id: String,
    pub embedding: Vec<f32>,
}

pub fn read_embedding_input<P: AsRef<Path>>(path: P) -> Result<Vec<EmbeddingRecord>> {
    let f = File::open(path)?;
    let reader = BufReader::new(f);
    let mut out = Vec::new();

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let rec: EmbeddingRecord = serde_json::from_str(&line)?;
        out.push(rec);
    }

    Ok(out)
}

pub fn write_embeddings<P: AsRef<Path>>(path: P, embeddings: &[EmbeddingOut]) -> Result<()> {
    let file = File::create(path)?;
    for e in embeddings {
        let s = serde_json::to_string(e)?;
        use std::io::Write;
        writeln!(&file, "{}", s)?;
    }
    Ok(())
}

pub fn deterministic_embed(text: &str, dim: usize) -> Vec<f32> {
    let hash = blake3::hash(text.as_bytes());
    let bytes = hash.as_bytes();

    let mut out = Vec::with_capacity(dim);
    for i in 0..dim {
        let b = bytes[i % bytes.len()];
        let v = (b as f32 / 127.5) - 1.0;
        out.push(v);
    }

    out
}
