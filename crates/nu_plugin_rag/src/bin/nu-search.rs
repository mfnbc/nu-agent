use anyhow::{anyhow, Context, Result};
use clap::Parser;
use nu_plugin_rag::DocRecord;
use rayon::prelude::*;
use rmp_serde::decode::from_read;
use serde_json::Value as JsonValue;
use std::fs::File;
use std::io::{self, Read, Write};
use std::path::Path;

/// Nu-search: fast linear scan over normalized embeddings stored in a MessagePack
/// array (data/nu_docs.msgpack). Accepts a query vector (MessagePack or NUON)
/// via --query-vec (path or '-' for stdin) and returns top-K results.
#[derive(Parser, Debug)]
#[command(author, version, about = "nu-search: fast linear embedding scan")]
struct Args {
    /// Path to msgpack docs (MessagePack array of records). Default: data/nu_docs.msgpack
    #[arg(long, default_value = "data/nu_docs.msgpack")]
    input: String,

    /// Query vector file path or '-' for stdin. Accepts MessagePack array of f32
    /// or NUON/JSON array of numbers. If omitted, read from stdin.
    #[arg(long)]
    query_vec: Option<String>,

    /// How many top results to return
    #[arg(long, default_value_t = 5)]
    top_k: usize,

    /// Output format: msgpack (default), nuon, json, lines
    #[arg(long, default_value = "msgpack")]
    out_format: String,

    /// Include a short snippet (first 160 chars) in results
    #[arg(long, default_value_t = false)]
    with_snippet: bool,

    /// Accept query vector input format explicitly: msgpack or nuon. If omitted we
    /// try to detect based on first bytes/contents.
    #[arg(long)]
    query_format: Option<String>,
}

// Reuse the shared DocRecord from nu_agent_common to guarantee MessagePack
// compatibility.
// Note: DocRecord has text: String and metadata: Option<JsonValue>

fn read_docs_msgpack<P: AsRef<Path>>(path: P) -> Result<Vec<DocRecord>> {
    let p = path.as_ref();
    let f = File::open(p).with_context(|| format!("opening doc msgpack: {}", p.display()))?;
    let v: Vec<DocRecord> = from_read(f).context("decoding msgpack docs array")?;
    Ok(v)
}

fn read_query_vec(path_opt: Option<&str>, explicit_format: Option<&str>) -> Result<Vec<f32>> {
    // Read bytes from path or stdin
    let mut buf = Vec::new();
    match path_opt {
        Some("-") | None => {
            let mut stdin = io::stdin();
            stdin.read_to_end(&mut buf)?;
        }
        Some(p) => {
            let mut f = File::open(p).with_context(|| format!("opening query vec: {}", p))?;
            f.read_to_end(&mut buf)?;
        }
    }

    // If explicit_format == "msgpack" try that first
    if let Some(fmt) = explicit_format {
        if fmt.eq_ignore_ascii_case("msgpack") {
            let mut de = rmp_serde::Deserializer::new(&buf[..]);
            let v: Vec<f32> =
                Deserialize::deserialize(&mut de).context("decoding query vec from msgpack")?;
            return Ok(v);
        } else if fmt.eq_ignore_ascii_case("nuon") {
            // NUON is textual JSON-like; parse as JSON array
            let s = String::from_utf8(buf)?;
            let v: Vec<f32> = serde_json::from_str(&s).context("parsing query nuon/json array")?;
            return Ok(v);
        }
    }

    // Try detect: if first byte is '{' or '[' assume JSON/NUON textual
    if !buf.is_empty() {
        let first = buf[0];
        if first == b'[' || first == b'{' || first == b' ' || first == b'\n' {
            let s = String::from_utf8(buf)?;
            // try JSON
            if let Ok(v) = serde_json::from_str::<Vec<f32>>(&s) {
                return Ok(v);
            }
            // Fallback: try to parse whitespace-separated floats
            let nums = s
                .split_whitespace()
                .filter(|s| !s.is_empty())
                .map(|s| s.parse::<f32>())
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| anyhow!("parsing floats: {}", e))?;
            return Ok(nums);
        } else {
            // Try MessagePack decode
            let mut de = rmp_serde::Deserializer::new(&buf[..]);
            if let Ok(v) = rmp_serde::from_read_ref::<_, Vec<f32>>(&buf) {
                return Ok(v);
            }
            // Fallback: attempt whitespace parse
            let s = String::from_utf8(buf)?;
            let nums = s
                .split_whitespace()
                .filter(|s| !s.is_empty())
                .map(|s| s.parse::<f32>())
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| anyhow!("parsing floats: {}", e))?;
            return Ok(nums);
        }
    }

    Err(anyhow!("empty query vector input"))
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
}

fn is_normalized(v: &[f32], eps: f32) -> bool {
    let sum: f32 = v.iter().map(|x| x * x).sum();
    (sum - 1.0).abs() <= eps
}

fn write_results_msgpack<P: AsRef<Path>>(path: Option<P>, records: &Vec<JsonValue>) -> Result<()> {
    let buf = rmp_serde::to_vec(records).context("encoding results to msgpack")?;
    match path {
        Some(p) => std::fs::write(p, buf).context("writing msgpack results file")?,
        None => {
            // write to stdout
            let mut out = io::stdout();
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();

    rayon::ThreadPoolBuilder::new().build_global().ok();

    let docs = read_docs_msgpack(&args.input)?;
    if docs.is_empty() {
        println!("[]");
        return Ok(());
    }

    let q = read_query_vec(args.query_vec.as_deref(), args.query_format.as_deref())?;
    let dim = docs[0].embedding.len();
    if q.len() != dim {
        anyhow::bail!("dimension mismatch: query {} vs doc {}", q.len(), dim);
    }

    // Validate normalization on a sample (or all). Fail fast if not normalized.
    if !is_normalized(&q, 1e-3) {
        anyhow::bail!("query vector is not normalized (expected unit length). Please normalize or use embed_runner to produce unit vectors.");
    }
    for (i, d) in docs.iter().enumerate().take(5) {
        if !is_normalized(&d.embedding, 1e-2) {
            anyhow::bail!("document embedding at index {} (id={}) is not normalized; re-run embed_runner to normalize embeddings", i, d.id);
        }
    }

    // Compute dot products in parallel (document embeddings are expected normalized)
    let mut scores: Vec<(usize, f32)> = docs
        .par_iter()
        .enumerate()
        .map(|(i, r)| (i, dot(&q, &r.embedding)))
        .collect();

    let k = args.top_k.min(scores.len());
    // Select top-k without full sort
    if scores.len() > k {
        let (left, _) = scores.select_nth_unstable_by(k, |a, b| {
            a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)
        });
        scores = left.to_vec();
    }
    // sort descending
    scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    // Build result objects
    let mut results: Vec<JsonValue> = Vec::with_capacity(k);
    for (idx, score) in scores.into_iter().take(k) {
        let doc = &docs[idx];
        let mut obj = serde_json::Map::new();
        obj.insert("id".to_string(), JsonValue::String(doc.id.clone()));
        obj.insert("score".to_string(), JsonValue::from(score));
        obj.insert("idx".to_string(), JsonValue::from(idx));
        if args.with_snippet {
            let s = doc.text.clone().unwrap_or_default();
            let snippet: String = s.chars().take(160).collect();
            obj.insert("snippet".to_string(), JsonValue::String(snippet));
        }
        results.push(JsonValue::Object(obj));
    }

    match args.out_format.as_str() {
        "msgpack" => {
            let buf = rmp_serde::to_vec(&results).context("encoding results to msgpack")?;
            let mut out = io::stdout();
            out.write_all(&buf)?;
        }
        "nuon" | "json" => {
            println!("{}", serde_json::to_string_pretty(&results)?);
        }
        "lines" => {
            for r in &results {
                let id = r.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let score = r.get("score").and_then(|v| v.as_f64()).unwrap_or(0.0);
                println!("{} {}", id, score);
            }
        }
        other => anyhow::bail!("unsupported out-format: {}", other),
    }

    Ok(())
}
