mod parser;
mod types;

use std::fs;
use std::path::PathBuf;

use anyhow::Context;
use clap::Parser;
use parser::{split_markdown, SplitterConfig};

#[derive(Debug, Parser)]
#[command(name = "nu-shredder", about = "Deterministic semantic Markdown splitter for Nu docs")]
struct Args {
    /// Markdown file to shred.
    path: PathBuf,

    /// Source corpus label (nu_book, nu_cookbook, nu_help).
    #[arg(long)]
    source: Option<String>,

    /// Attach code fences to the surrounding section chunk instead of emitting standalone example chunks.
    #[arg(long)]
    attach_code_blocks: bool,
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let markdown = fs::read_to_string(&args.path)
        .with_context(|| format!("failed to read markdown file: {}", args.path.display()))?;

    let checksum = blake3::hash(markdown.as_bytes()).to_hex().to_string();
    let source = args
        .source
        .unwrap_or_else(|| infer_source(&args.path));

    let config = SplitterConfig {
        source,
        path: args.path.display().to_string(),
        checksum,
        attach_code_blocks: args.attach_code_blocks,
    };

    for chunk in split_markdown(&markdown, config) {
        println!("{}", serde_json::to_string(&chunk)?);
    }

    Ok(())
}

fn infer_source(path: &PathBuf) -> String {
    let lower = path.to_string_lossy().to_lowercase();
    if lower.contains("cookbook") {
        "nu_cookbook".to_string()
    } else if lower.contains("book") || lower.contains("commands") {
        "nu_book".to_string()
    } else {
        "nu_help".to_string()
    }
}
