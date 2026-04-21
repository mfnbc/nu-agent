use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Write};

fn main() -> anyhow::Result<()> {
    let in_path = "build/nu_ingest/chunks.nuon";
    let out_vectors = "data/nu_docs_vectors.nuon";
    let out_command_map = "data/command_map.nuon";
    let out_embed = "build/nu_ingest/embedding_input.nuon";

    fs::create_dir_all("data")?;
    fs::create_dir_all("build/nu_ingest")?;

    let f = File::open(in_path)?;
    let reader = BufReader::new(f);

    let mut cmd_map: HashMap<String, serde_json::Map<String, Value>> = HashMap::new();
    let mut embed_out = File::create(out_embed)?;
    let mut vec_rows: Vec<Value> = Vec::new();

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(&line) {
            Ok(x) => x,
            Err(_) => continue,
        };

        // accumulate rows; we'll write them as a JSON array (NUON-accepting) below
        vec_rows.push(v.clone());

        // build command map entries
        if let Some(tax) = v.get("taxonomy") {
            if let Some(cmds) = tax.get("commands") {
                if let Some(arr) = cmds.as_array() {
                    for c in arr {
                        if let Some(cmd_str) = c.as_str() {
                            let key = cmd_str.to_lowercase();
                            if !cmd_map.contains_key(&key) {
                                // id from v.id
                                let id = v
                                    .get("id")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let mut map = serde_json::Map::new();
                                map.insert("id".to_string(), Value::String(id));
                                map.insert(
                                    "display".to_string(),
                                    Value::String(cmd_str.to_string()),
                                );
                                cmd_map.insert(key, map);
                            }
                        }
                    }
                }
            }
        }

        // collect embedding_input if present
        if let Some(e) = v.get("embedding_input") {
            if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                let text = if e.is_string() { e.as_str().unwrap().to_string() } else { e.to_string() };
                let o = serde_json::json!({"id": id, "text": text});
                vec!push_embed(&mut embed_rows, o);
            }
        }
    }

    // write vectors as a top-level JSON array (NUON)
    let mut vecf = File::create(out_vectors)?;
    vecf.write_all(serde_json::to_string_pretty(&vec_rows)?.as_bytes())?;

    // write embedding_input as a NUON JSON array
    let mut embedf = File::create(out_embed)?;
    embedf.write_all(serde_json::to_string_pretty(&embed_rows)?.as_bytes())?;

    // write command_map.nuon
    let mut out_map = serde_json::Map::new();
    for (k, v) in cmd_map {
        out_map.insert(k, Value::Object(v));
    }
    let out_value = Value::Object(out_map);
    let mut cmf = File::create(out_command_map)?;
    cmf.write_all(serde_json::to_string_pretty(&out_value)?.as_bytes())?;

    println!(
        "wrote: {} vectors, {} commands, embeddings written to {}",
        fs::metadata(out_vectors)?.len(),
        fs::metadata(out_command_map)?.len(),
        out_embed
    );

    Ok(())
}
