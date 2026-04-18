use std::fs::File;
use std::io::{self, BufRead};

use clap::Parser;
use serde::Serialize;

#[derive(Parser)]
struct Args {
    /// Query string to match
    #[arg(long)]
    query: String,

    /// Path to command_map.json (optional). If provided, use its keys as candidates.
    #[arg(long)]
    map_path: Option<String>,

    /// Number of top matches to return
    #[arg(long, default_value_t = 5)]
    top: usize,
}

#[derive(Serialize)]
struct CandidateOut {
    key: String,
    display: Option<String>,
    score: f64,
}

fn score_candidate(query: &str, candidate: &str) -> f64 {
    // Use normalized Levenshtein (via strsim::levenshtein) and Jaro-Winkler
    let lev = strsim::levenshtein(query, candidate) as f64;
    let max_len = query.len().max(candidate.len()) as f64;
    let lev_norm = if max_len == 0.0 {
        1.0
    } else {
        1.0 - (lev / max_len)
    };

    let jw = strsim::jaro_winkler(query, candidate);

    // Weighted combination (favor exact/substr via jw slightly)
    (0.6 * jw + 0.4 * lev_norm) * 100.0
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let q = args.query.to_lowercase();

    let mut candidates: Vec<(String, Option<String>)> = Vec::new();

    if let Some(path) = args.map_path {
        let f = File::open(path)?;
        let v: serde_json::Value = serde_json::from_reader(f)?;
        if let Some(obj) = v.as_object() {
            for (k, v) in obj.iter() {
                let display = v
                    .get("display")
                    .and_then(|d| d.as_str())
                    .map(|s| s.to_string());
                candidates.push((k.to_string(), display));
            }
        }
    } else {
        // read newline candidates from stdin
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let l = line?;
            if l.trim().is_empty() {
                continue;
            }
            candidates.push((l.clone(), None));
        }
    }

    let mut scored: Vec<CandidateOut> = candidates
        .into_iter()
        .map(|(k, display)| {
            let key_norm = k.to_lowercase();
            let s = score_candidate(&q, &key_norm);
            CandidateOut {
                key: k,
                display,
                score: (s * 100.0).round() / 100.0,
            }
        })
        .collect();

    scored.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let out: Vec<_> = scored.into_iter().take(args.top).collect();

    println!("{}", serde_json::to_string(&out)?);

    Ok(())
}
