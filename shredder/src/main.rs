use blake3;
use pulldown_cmark::{Event, Options, Parser, Tag};
use rmp_serde::to_vec_named;
use serde::Deserialize;
use serde::Serialize;
use std::env;
use std::fs;
use std::io::{self, Write};

#[derive(Serialize)]
struct NuDocChunk<'a> {
    // Identity
    path: &'a str,
    id: String,

    // Hierarchy
    title: Option<String>,
    heading_path: Vec<String>,

    // Data
    text: String,

    // Taxonomy (minimal for now)
    taxonomy: Taxonomy,

    // Deterministic embedding input
    embedding_input: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct Taxonomy {
    commands: Vec<String>,
    tags: Vec<String>,
}

fn checksum(s: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(s.as_bytes());
    hasher.finalize().to_hex().to_string()
}

/// Shred markdown into a vector of NuDocChunk-like structs.
/// This implementation uses pulldown-cmark to stream events and split
/// on heading boundaries. It's intentionally minimal but deterministic.
fn shred_markdown<'a>(path: &'a str, md: &'a str) -> Vec<NuDocChunk<'a>> {
    let mut chunks: Vec<NuDocChunk> = Vec::new();

    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    let parser = Parser::new_ext(md, options);

    let mut current = String::new();
    let mut heading_stack: Vec<String> = Vec::new();
    let mut title: Option<String> = None;
    let mut in_heading = false;

    for ev in parser {
        match ev {
            Event::Start(Tag::Heading(_level, ..)) => {
                // On encountering a new heading start, flush current chunk (if any)
                if !current.trim().is_empty() {
                    let idx = chunks.len();
                    let content_checksum = checksum(&current);
                    let id = format!("{}::{}::{}", path, idx, content_checksum);
                    let embedding_input = format!(
                        "Title: {}\nPath: {}\nContent:\n{}",
                        title.clone().unwrap_or_default(),
                        heading_stack.join(" > "),
                        current
                    );
                    let chunk = NuDocChunk {
                        path,
                        id: checksum(&id),
                        title: title.clone(),
                        heading_path: heading_stack.clone(),
                        text: current.clone(),
                        taxonomy: Taxonomy {
                            commands: vec![],
                            tags: vec![],
                        },
                        embedding_input,
                    };
                    chunks.push(chunk);
                    current.clear();
                }
                in_heading = true;
            }
            Event::End(Tag::Heading(_level, ..)) => {
                in_heading = false;
            }
            Event::Text(t) => {
                if in_heading {
                    // treat first heading encountered as title if title is empty
                    let s = t.to_string();
                    if title.is_none() {
                        title = Some(s.clone());
                    }
                    // push heading into stack (for simplicity we replace last level)
                    if heading_stack.is_empty() {
                        heading_stack.push(s)
                    } else {
                        // replace last heading with current; more advanced level tracking omitted for brevity
                        heading_stack.pop();
                        heading_stack.push(s);
                    }
                } else {
                    current.push_str(&t);
                    current.push('\n');
                }
            }
            Event::Code(t) => {
                current.push_str(&format!("``{}``\n", t));
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                // CodeBlockKind isn't Display; use Debug to keep language info
                current.push_str(&format!("```{:?}\n", kind));
            }
            Event::End(Tag::CodeBlock(_)) => {
                current.push_str("```\n");
            }
            Event::Start(Tag::Link(_, dest, _)) => {
                current.push_str(&format!("[link: {}] ", dest));
            }
            Event::SoftBreak | Event::HardBreak => {
                current.push('\n');
            }
            _ => {}
        }
    }

    // final flush
    if !current.trim().is_empty() {
        let idx = chunks.len();
        let content_checksum = checksum(&current);
        let id = format!("{}::{}::{}", path, idx, content_checksum);
        let embedding_input = format!(
            "Title: {}\nPath: {}\nContent:\n{}",
            title.clone().unwrap_or_default(),
            heading_stack.join(" > "),
            current
        );
        let chunk = NuDocChunk {
            path,
            id: checksum(&id),
            title,
            heading_path: heading_stack,
            text: current,
            taxonomy: Taxonomy {
                commands: vec![],
                tags: vec![],
            },
            embedding_input,
        };
        chunks.push(chunk);
    }

    chunks
}

#[derive(Deserialize, Serialize)]
struct OutRecord {
    path: String,
    id: String,
    title: Option<String>,
    heading_path: Vec<String>,
    text: String,
    taxonomy: Taxonomy,
    embedding_input: String,
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: shredder <markdown-file> [--output <file>]");
        std::process::exit(2);
    }

    let path = &args[1];
    // This shredder chooses MessagePack as the canonical machine format.
    // It writes a per-file chunks MessagePack to build/nu_ingest/<stem>.chunks.msgpack

    let content = fs::read_to_string(path)?;

    let chunks = shred_markdown(path, &content);

    // Convert to serializable records
    let records: Vec<OutRecord> = chunks
        .into_iter()
        .map(|c| OutRecord {
            path: c.path.to_string(),
            id: c.id,
            title: c.title,
            heading_path: c.heading_path,
            text: c.text,
            taxonomy: c.taxonomy,
            embedding_input: c.embedding_input,
        })
        .collect();

    // Ensure output directory exists
    let out_dir = std::path::Path::new("build/nu_ingest");
    if !out_dir.exists() {
        std::fs::create_dir_all(out_dir)?;
    }

    // Write canonical chunks msgpack file per input markdown
    let stem = std::path::Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("shred");
    let out_chunks = out_dir.join(format!("{}.chunks.msgpack", stem));
    // Serialize records as MessagePack maps (named struct fields) so downstream
    // consumers (nushell scripts) can access fields by name (eg. $chunk.taxonomy)
    let buf = to_vec_named(&records)?;
    fs::write(&out_chunks, buf)?;

    // Also write an embedding_input msgpack (array of {id, text}) for fast consumption
    #[derive(Serialize)]
    struct EmbRec<'a> {
        id: &'a str,
        text: &'a str,
    }

    let emb: Vec<EmbRec> = records
        .iter()
        .map(|r| EmbRec {
            id: &r.id,
            text: &r.embedding_input,
        })
        .collect();
    let out_emb = out_dir.join(format!("{}.embedding_input.msgpack", stem));
    let emb_buf = to_vec_named(&emb)?;
    fs::write(&out_emb, emb_buf)?;

    // Print produced paths so callers can find them
    println!("{}", out_chunks.display());
    println!("{}", out_emb.display());

    Ok(())
}
