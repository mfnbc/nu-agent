use anyhow::Result;
use rmp_serde::{Deserializer, Serializer};
use serde::{Deserialize, Serialize};
use std::fs;
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

/// Canonical persisted document record produced by embed_runner and stored in
/// data/nu_docs.msgpack. Keep this stable to ensure MessagePack compatibility
/// between the runner and consumers like nu-search.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct DocRecord {
    pub id: String,
    pub text: String,
    pub embedding: Vec<f32>,
    pub metadata: Option<serde_json::Value>,
}

pub fn read_embedding_input<P: AsRef<Path>>(path: P) -> Result<Vec<EmbeddingRecord>> {
    let p = path.as_ref();
    // infer by extension: .msgpack or .mpk => read as MessagePack array, otherwise expect NUON (textual JSON array)
    if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
        if ext.eq_ignore_ascii_case("msgpack") || ext.eq_ignore_ascii_case("mpk") {
            // Read entire file and parse as a single msgpack array of records
            let bytes = fs::read(p)?;
            let mut de = Deserializer::new(&bytes[..]);
            let v: Vec<EmbeddingRecord> = Deserialize::deserialize(&mut de)?;
            return Ok(v);
        }
    }

    // Default: expect NUON. If path ends with .nuon, read via Nushell-friendly JSON text.
    if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
        if ext.eq_ignore_ascii_case("nuon") {
            // NUON is textual JSON-like; read as string then parse as JSON array
            let s = std::fs::read_to_string(p)?;
            let v: Vec<EmbeddingRecord> = serde_json::from_str(&s)?;
            return Ok(v);
        }
    }
    // If we reach here, try to read as NUON (textual JSON array) as a last resort
    let s = std::fs::read_to_string(p)?;
    let v: Vec<EmbeddingRecord> = serde_json::from_str(&s)?;
    Ok(v)
}

pub fn write_embeddings<P: AsRef<Path>>(path: P, embeddings: &[EmbeddingOut]) -> Result<()> {
    let p = path.as_ref();
    if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
        if ext.eq_ignore_ascii_case("msgpack") || ext.eq_ignore_ascii_case("mpk") {
            // Serialize the entire vector as a single MessagePack array
            let mut buf = Vec::new();
            embeddings.serialize(&mut Serializer::new(&mut buf))?;
            std::fs::write(p, buf)?;
            return Ok(());
        }
    }
    // Default: write as NUON (pretty JSON array) for human inspection
    let s = serde_json::to_string_pretty(embeddings)?;
    std::fs::write(p, s.as_bytes())?;
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
