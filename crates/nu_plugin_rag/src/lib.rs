use anyhow::Result;
use rmp_serde::Deserializer;
use serde::{Deserialize, Serialize};
use std::fs;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct EmbRec {
    pub id: String,
    pub vector: Vec<f32>,
}

/// Build a simple JSON index file from a msgpack vectors file.
pub fn build_index(vec_path: &str, _chunks_path: &str, out_path: &str) -> Result<()> {
    let buf = fs::read(vec_path)?;
    // try to decode as an array of EmbRec
    let vecs: Vec<EmbRec> = match rmp_serde::from_slice(&buf) {
        Ok(v) => v,
        Err(_) => {
            // fallback: stream-decode concatenated maps
            let mut de = Deserializer::new(&buf[..]);
            let mut items = Vec::new();
            loop {
                match EmbRec::deserialize(&mut de) {
                    Ok(r) => items.push(r),
                    Err(_) => break,
                }
            }
            items
        }
    };

    let dim = vecs.get(0).map(|v| v.vector.len()).unwrap_or(0);
    let ids: Vec<String> = vecs.iter().map(|v| v.id.clone()).collect();
    let vectors: Vec<f32> = vecs.iter().flat_map(|v| v.vector.clone()).collect();

    let index = serde_json::json!({"dim": dim, "ids": ids, "vectors": vectors});
    fs::write(out_path, serde_json::to_vec(&index)?)?;
    Ok(())
}
