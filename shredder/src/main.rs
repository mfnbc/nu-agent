use blake3;
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};
use rmp_serde::to_vec_named;
use serde::Deserialize;
use serde::Serialize;
use std::env;
use std::fs;
use std::io::Write;

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
    idiom_weight: i32,
}

// Simple heuristic to score how "idiomatic" a code block is.
fn calculate_idiom_score(code: &str) -> i32 {
    let mut score = 0;
    if code.matches('|').count() > 2 {
        score += 1;
    }
    let structured_tokens = [
        "upsert", "insert", "update", "merge", "reduce", "flatten", "wrap",
    ];
    if structured_tokens.iter().any(|&t| code.contains(t)) {
        score += 1;
    }
    if code.contains("metadata") || code.contains("$in") || code.contains("explore") {
        score += 1;
    }
    score
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
    // Whether the current chunk contains a Nushell fenced code block
    let mut current_has_nu_code: bool = false;
    // Accumulate the raw code text for the current chunk (to compute idiom score)
    let mut current_code_text: String = String::new();

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

                    let mut taxonomy = Taxonomy {
                        commands: vec![],
                        tags: vec![],
                        idiom_weight: 0,
                    };
                    if current_has_nu_code {
                        taxonomy.tags.push("high_priority".to_string());
                        taxonomy.idiom_weight = calculate_idiom_score(&current_code_text);
                    }

                    let chunk = NuDocChunk {
                        path,
                        id: checksum(&id),
                        title: title.clone(),
                        heading_path: heading_stack.clone(),
                        text: current.clone(),
                        taxonomy,
                        embedding_input,
                    };
                    chunks.push(chunk);
                    current.clear();
                    current_has_nu_code = false;
                    current_code_text.clear();
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
                    // Also accumulate into code text if we're inside a fenced code block
                    if current_has_nu_code {
                        current_code_text.push_str(&t);
                        current_code_text.push('\n');
                    }
                }
            }
            Event::Code(t) => {
                current.push_str(&format!("``{}``\n", t));
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                // If fenced, check the language identifier for nushell/nu
                match kind {
                    CodeBlockKind::Fenced(lang) => {
                        let lang_str = lang.to_string();
                        if !lang_str.is_empty() {
                            let l = lang_str.to_lowercase();
                            if l.starts_with("nu") || l.contains("nushell") {
                                current_has_nu_code = true;
                            }
                        }
                        current.push_str(&format!("```{}\n", lang_str));
                    }
                    CodeBlockKind::Indented => {
                        current.push_str("```\n");
                    }
                }
            }
            Event::End(Tag::CodeBlock(_)) => {
                current.push_str("```\n");
                // closing a code block: keep current_code_text as-is (we may see multiple code blocks per chunk)
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

        let mut taxonomy = Taxonomy {
            commands: vec![],
            tags: vec![],
            idiom_weight: 0,
        };
        if current_has_nu_code {
            taxonomy.tags.push("high_priority".to_string());
            taxonomy.idiom_weight = calculate_idiom_score(&current_code_text);
        }

        let chunk = NuDocChunk {
            path,
            id: checksum(&id),
            title,
            heading_path: heading_stack,
            text: current,
            taxonomy,
            embedding_input,
        };
        chunks.push(chunk);
    }

    chunks
}

#[derive(Deserialize, Serialize, Clone)]
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
    // It updates the canonical combined files under build/nu_ingest.

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
            // Populate taxonomy.commands for command docs based on path
            taxonomy: {
                let mut tx = c.taxonomy.clone();
                // If this looks like a command doc under commands/docs, use the file stem
                if c.path.contains("/commands/docs/") {
                    if let Some(stem) = std::path::Path::new(c.path)
                        .file_stem()
                        .and_then(|s| s.to_str())
                    {
                        tx.commands = vec![stem.to_string()];
                    }
                } else if c.path.contains("/commands/") {
                    // fallback: if it's under /commands/ but not /commands/docs/, try to use the file stem
                    if let Some(stem) = std::path::Path::new(c.path)
                        .file_stem()
                        .and_then(|s| s.to_str())
                    {
                        tx.commands = vec![stem.to_string()];
                    }
                }
                tx
            },
            embedding_input: c.embedding_input,
        })
        .collect();

    // Ensure output directory exists
    let out_dir = std::path::Path::new("build/nu_ingest");
    if !out_dir.exists() {
        std::fs::create_dir_all(out_dir)?;
    }

    // Build embedding_input records for aggregation
    #[derive(Serialize, Deserialize, Clone)]
    struct EmbRec {
        id: String,
        text: String,
    }

    let emb: Vec<EmbRec> = records
        .iter()
        .map(|r| EmbRec {
            id: r.id.clone(),
            text: r.embedding_input.clone(),
        })
        .collect();

    // --- Aggregation: update canonical combined files in build/nu_ingest ---
    // Read existing combined chunks.msgpack (if present), append current records,
    // and write back as a single MessagePack array with named maps.
    let combined_chunks_path = out_dir.join("chunks.msgpack");
    let mut combined_records: Vec<OutRecord> = if combined_chunks_path.exists() {
        match std::fs::read(&combined_chunks_path) {
            Ok(data) => match rmp_serde::from_slice::<Vec<OutRecord>>(&data) {
                Ok(mut existing) => {
                    existing.append(&mut records.clone());
                    existing
                }
                Err(_) => {
                    // If deserialization fails, overwrite with the current records
                    records.clone()
                }
            },
            Err(_) => records.clone(),
        }
    } else {
        records.clone()
    };

    let combined_buf = to_vec_named(&combined_records)?;
    fs::write(&combined_chunks_path, combined_buf)?;

    // Similarly aggregate embedding_input into build/nu_ingest/embedding_input.msgpack
    let combined_emb_path = out_dir.join("embedding_input.msgpack");
    let mut combined_emb: Vec<EmbRec> = if combined_emb_path.exists() {
        match std::fs::read(&combined_emb_path) {
            Ok(data) => match rmp_serde::from_slice::<Vec<EmbRec>>(&data) {
                Ok(mut existing) => {
                    existing.append(&mut emb.clone());
                    existing
                }
                Err(_) => emb.clone(),
            },
            Err(_) => emb.clone(),
        }
    } else {
        emb.clone()
    };

    let combined_emb_buf = to_vec_named(&combined_emb)?;
    fs::write(&combined_emb_path, combined_emb_buf)?;

    // Print combined paths so callers can find them
    println!("{}", combined_chunks_path.display());
    println!("{}", combined_emb_path.display());

    // Build command_map (lowercase command -> { id, display }) and write as msgpack
    use std::collections::BTreeMap;
    #[derive(Serialize)]
    struct CmdEntry {
        id: String,
        display: String,
    }

    let mut cmd_map: BTreeMap<String, CmdEntry> = BTreeMap::new();
    for rec in &combined_records {
        for cmd in &rec.taxonomy.commands {
            let key = cmd.to_lowercase();
            if !cmd_map.contains_key(&key) {
                cmd_map.insert(
                    key,
                    CmdEntry {
                        id: rec.id.clone(),
                        display: cmd.clone(),
                    },
                );
            }
        }
    }

    // Ensure data dir exists and write binary msgpack command_map
    let data_dir = std::path::Path::new("data");
    if !data_dir.exists() {
        std::fs::create_dir_all(data_dir)?;
    }
    let cmd_buf = to_vec_named(&cmd_map)?;
    let cmd_path = data_dir.join("command_map.msgpack");
    fs::write(&cmd_path, cmd_buf)?;

    Ok(())
}
