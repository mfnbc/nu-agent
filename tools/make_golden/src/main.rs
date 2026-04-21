use anyhow::Context;
use rmp_serde::from_slice;
use serde::Deserialize;
use std::fs;

#[derive(Deserialize)]
struct ChunkRec {
    id: String,
    embedding_input: Option<String>,
    text: Option<String>,
    taxonomy: Option<Taxonomy>,
}

#[derive(Deserialize)]
struct Taxonomy {
    idiom_weight: Option<i32>,
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: make_golden <chunks.msgpack> <out.msgpack>");
        std::process::exit(2);
    }
    let in_path = &args[1];
    let out_path = &args[2];

    let data = fs::read(in_path).context("read input")?;
    let recs: Vec<ChunkRec> = from_slice(&data).context("deserialize input msgpack")?;

    let mut out: Vec<serde_json::Value> = Vec::new();
    for r in recs {
        let weight = r.taxonomy.and_then(|t| t.idiom_weight).unwrap_or(0);
        if weight >= 2 {
            let text = r.text.or(r.embedding_input).unwrap_or_default();
            let v = serde_json::json!({"id": r.id, "text": text});
            out.push(v);
        }
    }

    let buf = rmp_serde::to_vec_named(&out).context("serialize output")?;
    fs::write(out_path, buf).context("write output")?;
    println!("wrote {} golden records to {}", out.len(), out_path);
    Ok(())
}
