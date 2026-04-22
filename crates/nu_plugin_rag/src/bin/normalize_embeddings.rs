use anyhow::Context;
use rmp_serde::Deserializer;
use serde::Deserialize;
use serde_json::Value as JsonVal;
use std::fs::File;
use std::io::Read;

fn normalize_record(v: JsonVal) -> JsonVal {
    // If the value is an array like [ [col1, col2, ...], [val1, val2, ...] ]
    // convert to a map { col1: val1, ... }
    if let JsonVal::Array(ref outer) = v {
        if outer.len() == 2 {
            if let (JsonVal::Array(ref cols), JsonVal::Array(ref vals)) = (&outer[0], &outer[1]) {
                // ensure cols are strings
                let mut map = serde_json::Map::with_capacity(cols.len());
                for (i, c) in cols.iter().enumerate() {
                    if let JsonVal::String(key) = c {
                        let value = vals.get(i).cloned().unwrap_or(JsonVal::Null);
                        map.insert(key.clone(), value);
                    } else {
                        // not string column names, bail to original
                        return v;
                    }
                }
                return JsonVal::Object(map);
            }
        }
    }
    // If already an object/map, return as-is
    v
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: normalize_embeddings <input.msgpack> <output.msgpack>");
        std::process::exit(2);
    }
    let in_path = &args[1];
    let out_path = &args[2];

    let mut f = File::open(in_path).context("open input")?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).context("read input bytes")?;

    let mut cur = std::io::Cursor::new(&buf);
    let mut docs: Vec<JsonVal> = Vec::new();

    loop {
        if (cur.position() as usize) >= buf.len() {
            break;
        }
        let mut de = Deserializer::new(&mut cur);
        match JsonVal::deserialize(&mut de) {
            Ok(v) => {
                let norm = normalize_record(v);
                docs.push(norm);
            }
            Err(err) => {
                // If we hit EOF or cannot parse, stop
                let msg = format!("deserialize error: {}", err);
                if msg.contains("EOF") || msg.contains("end of stream") {
                    break;
                }
                return Err(anyhow::anyhow!("deserialize failed: {}", err));
            }
        }
    }

    // Write as a single MessagePack array of maps
    let out_buf = rmp_serde::to_vec_named(&docs).context("serialize output")?;
    std::fs::write(out_path, out_buf).context("write output")?;

    eprintln!("Wrote {} records to {}", docs.len(), out_path);
    Ok(())
}
