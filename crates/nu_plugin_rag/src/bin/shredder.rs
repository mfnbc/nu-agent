use anyhow::Context;
use pulldown_cmark::{Event, Parser, Tag};
use rmp_serde::to_vec_named;
use serde::Serialize;
use std::fs;
use std::io::Write;
use std::time::Instant;

// Optional tokenizer/text-splitter imports
use text_splitter::{ChunkConfig, TextSplitter};
use tokenizers::Tokenizer;

#[derive(Serialize)]
struct ChunkRec {
    id: String,
    path: String,
    title: String,
    heading_path: Option<String>,
    embedding_input: String,
}

fn chunk_text(text: &str, max_chars: usize, overlap: usize) -> Vec<String> {
    if text.chars().count() <= max_chars {
        return vec![text.to_string()];
    }
    let mut out = Vec::new();
    let step = if max_chars > overlap {
        max_chars - overlap
    } else {
        max_chars
    };
    let mut start = 0usize;
    let chars: Vec<char> = text.chars().collect();
    while start < chars.len() {
        let end = usize::min(start + max_chars, chars.len());
        let s: String = chars[start..end].iter().collect();
        out.push(s);
        if end == chars.len() {
            break;
        }
        start += step;
    }
    out
}

fn chunk_text_by_tokens(
    text: &str,
    tokenizer_name: &str,
    max_tokens: usize,
    overlap: usize,
) -> anyhow::Result<Vec<String>> {
    // Load tokenizer via tokenizers pretrained loader (may fetch over HTTP)
    let tok = Tokenizer::from_pretrained(tokenizer_name, None)
        .map_err(|e| anyhow::anyhow!("loading tokenizer '{}': {}", tokenizer_name, e))?;

    let mut cfg = ChunkConfig::new(max_tokens).with_sizer(tok);
    // try to set overlap if supported by the crate
    cfg = cfg.with_overlap(overlap)?;
    let splitter = TextSplitter::new(cfg);
    // collect owned String chunks
    let chunks: Vec<String> = splitter.chunks(text).map(|s| s.to_string()).collect();
    Ok(chunks)
}

fn extract_title_and_text(md: &str) -> (String, String) {
    let parser = Parser::new(md);
    let mut title = String::new();
    let mut in_heading = false;
    let mut text_acc = String::new();
    for ev in parser {
        match ev {
            Event::Start(Tag::Heading(..)) => in_heading = true,
            Event::End(Tag::Heading(..)) => in_heading = false,
            Event::Text(t) => {
                if in_heading && title.is_empty() {
                    title = t.to_string();
                }
                text_acc.push_str(&t);
            }
            Event::Code(t) => text_acc.push_str(&t),
            _ => {}
        }
    }
    (title, text_acc)
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: shredder <file.md> [--max-chars N] [--overlap N]");
        std::process::exit(2);
    }
    let path = &args[1];
    let max_chars = args
        .iter()
        .position(|a| a == "--max-chars")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(1800);
    let overlap = args
        .iter()
        .position(|a| a == "--overlap")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(200);

    // Tokenizer-based options
    let tokenizer_name = args
        .iter()
        .position(|a| a == "--tokenizer")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.to_string())
        .or_else(|| std::env::var("SHREDDER_TOKENIZER").ok());

    let max_tokens = args
        .iter()
        .position(|a| a == "--max-tokens")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())
        .or_else(|| {
            std::env::var("SHREDDER_MAX_TOKENS")
                .ok()
                .and_then(|s| s.parse().ok())
        })
        .unwrap_or(512);

    let overlap_tokens = args
        .iter()
        .position(|a| a == "--overlap-tokens")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<usize>().ok())
        .or_else(|| {
            std::env::var("SHREDDER_OVERLAP_TOKENS")
                .ok()
                .and_then(|s| s.parse().ok())
        })
        .unwrap_or(64);

    let prepend_passage = args.iter().any(|a| a == "--prepend-passage")
        || std::env::var("SHREDDER_PREPEND_PASSAGE").ok().as_deref() == Some("1");

    let raw = fs::read_to_string(path).context("reading input file")?;
    let (title, text) = extract_title_and_text(&raw);

    // Decide whether to use tokenizer-based splitting or char-based fallback
    let start = Instant::now();
    let chunks = if let Some(tok_name) = tokenizer_name.as_deref() {
        eprintln!(
            "shredder: attempting tokenizer-based splitting using '{}'",
            tok_name
        );
        match chunk_text_by_tokens(&text, tok_name, max_tokens, overlap_tokens) {
            Ok(mut c) => {
                eprintln!(
                    "shredder: tokenizer split into {} chunks in {:?}",
                    c.len(),
                    start.elapsed()
                );
                c
            }
            Err(e) => {
                eprintln!(
                    "shredder: tokenizer split failed ({}), falling back to char-based: {}",
                    tok_name, e
                );
                chunk_text(&text, max_chars, overlap)
            }
        }
    } else {
        eprintln!("shredder: no tokenizer provided, using char-based splitting");
        chunk_text(&text, max_chars, overlap)
    };
    let mut out = std::io::stdout();
    for mut c in chunks {
        if prepend_passage {
            c = format!("passage: {}", c);
        }
        let id = blake3::hash(c.as_bytes()).to_hex().to_string();
        let rec = ChunkRec {
            id,
            path: path.to_string(),
            title: title.clone(),
            heading_path: None,
            embedding_input: c,
        };
        let buf = to_vec_named(&rec)?;
        out.write_all(&buf)?;
    }

    Ok(())
}
