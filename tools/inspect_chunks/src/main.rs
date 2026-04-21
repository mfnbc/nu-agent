use rmp_serde::from_slice;
use serde::Deserialize;
use std::fs;

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct Taxonomy {
    commands: Option<Vec<String>>,
    tags: Option<Vec<String>>,
    idiom_weight: Option<i32>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct OutRecord {
    path: String,
    id: String,
    title: Option<String>,
    heading_path: Option<Vec<String>>,
    text: Option<String>,
    taxonomy: Option<Taxonomy>,
    embedding_input: Option<String>,
}

fn main() -> anyhow::Result<()> {
    let p = "build/nu_ingest/chunks.msgpack";
    let data = fs::read(p)?;
    let recs: Vec<OutRecord> = from_slice(&data)?;
    eprintln!("Total records: {}", recs.len());
    // Collect records with idiom_weight and show top 10
    let mut with_score: Vec<(&OutRecord, i32)> = Vec::new();
    for r in &recs {
        let score = r
            .taxonomy
            .as_ref()
            .and_then(|t| t.idiom_weight)
            .unwrap_or(0i32);
        if score > 0 {
            with_score.push((r, score));
        }
    }
    with_score.sort_by(|a, b| b.1.cmp(&a.1));
    for (r, sc) in with_score.iter().take(10) {
        println!("SCORE: {}", sc);
        println!("PATH: {}", r.path);
        println!("ID: {}", r.id);
        if let Some(title) = &r.title {
            println!("TITLE: {}", title);
        }
        if let Some(ei) = &r.embedding_input {
            let sample: String = ei.lines().take(6).collect::<Vec<_>>().join("\n");
            println!("EMBEDDING_INPUT_SAMPLE:\n{}", sample);
        }
        println!("---");
    }

    // Final sanity check: print full 'text' for stor_insert and metadata_set if present
    let targets = ["stor_insert.md", "metadata_set.md"];
    for t in &targets {
        for r in &recs {
            if r.path.ends_with(t) {
                println!("\nFULL TEXT FOR {}:\n", t);
                if let Some(txt) = &r.text {
                    println!("{}", txt);
                } else {
                    println!("<no text field present>");
                }
            }
        }
    }
    Ok(())
}
