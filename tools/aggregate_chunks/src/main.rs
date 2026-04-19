use glob::glob;
use rmp_serde::Deserializer;
use serde_json::Value;
use std::fs::File;
use std::io::{BufReader, Read, Write};
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Collect all .chunks.msgpack files
    let mut combined: Vec<Value> = Vec::new();

    for entry in glob("build/nu_ingest/*.chunks.msgpack")? {
        let path = entry?;
        let file = File::open(&path)?;
        let mut reader = BufReader::new(file);

        // Read the entire file into memory
        let mut buf = Vec::new();
        reader.read_to_end(&mut buf)?;

        // Try to deserialize as an array of objects
        let mut de = Deserializer::new(&buf[..]);
        let v: Result<Vec<Value>, _> = serde::Deserialize::deserialize(&mut de);
        match v {
            Ok(mut items) => combined.append(&mut items),
            Err(_) => {
                // If file is a single object, try deserializing as Value
                let mut de2 = Deserializer::new(&buf[..]);
                let single: Value = serde::Deserialize::deserialize(&mut de2)?;
                // If it's an array, extend; otherwise push single
                if single.is_array() {
                    if let Some(arr) = single.as_array() {
                        combined.extend_from_slice(arr);
                    }
                } else {
                    combined.push(single);
                }
            }
        }
    }

    // Serialize combined as named maps into MessagePack
    let out = rmp_serde::to_vec_named(&combined)?;
    let out_path = Path::new("build/nu_ingest/chunks.msgpack");
    let mut out_file = File::create(out_path)?;
    out_file.write_all(&out)?;

    println!("Wrote {} chunks to {}", combined.len(), out_path.display());

    Ok(())
}
