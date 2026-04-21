use anyhow::Result;
use clap::{Parser, Subcommand};
use nu_plugin_rag::{blake3_of_file, download_to_path};
use serde_json::json;

#[derive(Parser)]
#[command(name = "nu_plugin_rag", about = "nu_plugin_rag CLI (lightweight stub)")]
struct Cli {
    #[command(subcommand)]
    cmd: Commands,
}

#[derive(Subcommand)]
enum Commands {
    PrepareDeps {
        #[arg(long, default_value = "")]
        out_dir: String,
    },
    Build {
        #[arg(long)]
        input: String,
        #[arg(long, default_value = "build/rag/nu-docs")]
        out_dir: String,
        #[arg(long)]
        attach_code_blocks: bool,
        #[arg(long)]
        force: bool,
    },
    Status {
        #[arg(long)]
        out_dir: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.cmd {
        Commands::PrepareDeps { out_dir } => {
            // Prepare dependencies: create cache dir and optionally download vetted artifacts.
            let cache_dir = if !out_dir.is_empty() {
                out_dir
            } else {
                dirs::cache_dir()
                    .map(|p| p.join("nu-agent"))
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or("./.cache/nu-agent".to_string())
            };
            std::fs::create_dir_all(&cache_dir).ok();

            // Attempt to read a local prepare catalog for approved artifacts to download.
            let mut downloaded = false;
            let fastembed_checksum: Option<String> = None;

            let catalog_path =
                std::path::Path::new("crates/nu_plugin_rag/data/prepare_catalog.json");
            if catalog_path.exists() {
                if let Ok(s) = std::fs::read_to_string(catalog_path) {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) {
                        if let Some(arts) = v.get("artifacts").and_then(|a| a.as_array()) {
                            // We'll download each artifact into the cache_dir and verify blake3
                            let mut cache_entries = Vec::new();
                            for art in arts {
                                if let Some(name) = art.get("name").and_then(|n| n.as_str()) {
                                    if let Some(url) = art.get("url").and_then(|u| u.as_str()) {
                                        let fname = art
                                            .get("name")
                                            .and_then(|n| n.as_str())
                                            .unwrap_or(name)
                                            .to_string();
                                        let dest = std::path::Path::new(&cache_dir).join(&fname);
                                        // If a file matching the URL basename already exists in cache, prefer it
                                        let url_basename = std::path::Path::new(url)
                                            .file_name()
                                            .and_then(|s| s.to_str())
                                            .unwrap_or("");
                                        let alt_path =
                                            std::path::Path::new(&cache_dir).join(url_basename);

                                        if dest.exists() {
                                            // ok
                                        } else if alt_path.exists() {
                                            // use existing alt path by copying to dest (or using alt)
                                            let _ = std::fs::copy(&alt_path, &dest);
                                        } else {
                                            match download_to_path(url, &dest) {
                                                Ok(()) => {
                                                    downloaded = true;
                                                    #[cfg(unix)]
                                                    {
                                                        use std::os::unix::fs::PermissionsExt;
                                                        let mut perms =
                                                            std::fs::metadata(&dest)?.permissions();
                                                        perms.set_mode(0o644);
                                                        std::fs::set_permissions(&dest, perms).ok();
                                                    }
                                                }
                                                Err(e) => {
                                                    eprintln!("failed to download {}: {}", name, e);
                                                    continue;
                                                }
                                            }
                                        }

                                        if dest.exists() {
                                            let actual = blake3_of_file(&dest).ok();
                                            let expected = art
                                                .get("blake3")
                                                .and_then(|b| b.as_str())
                                                .map(|s| s.to_string());
                                            if let (Some(a), Some(e)) =
                                                (actual.clone(), expected.clone())
                                            {
                                                if a != e {
                                                    eprintln!("checksum mismatch for {}: expected {} got {}", name, e, a);
                                                    // remove bad file
                                                    let _ = std::fs::remove_file(&dest);
                                                    continue;
                                                }
                                            }

                                            cache_entries.push(serde_json::json!({"name": name, "path": dest.to_string_lossy(), "blake3": actual}));
                                        }
                                    }
                                }
                            }

                            // write cache-catalog.json into cache dir
                            let cache_catalog = serde_json::json!({"cached_at": chrono::Utc::now().to_rfc3339(), "entries": cache_entries});
                            let _ = std::fs::write(
                                std::path::Path::new(&cache_dir).join("cache-catalog.json"),
                                serde_json::to_string_pretty(&cache_catalog)?,
                            );
                        }
                    }
                }
            }

            let marker = format!("{}/prepare-deps.ok", cache_dir);
            let _ = std::fs::write(&marker, "ok");

            let resp = json!({"status":"ok", "action":"prepare-deps", "cache_dir": cache_dir, "fastembed_downloaded": downloaded, "fastembed_checksum": fastembed_checksum, "marker": marker});
            println!("{}", resp);
        }
        Commands::Build {
            input,
            out_dir,
            attach_code_blocks: _,
            force: _,
        } => {
            // Orchestrate: clone (if necessary), run shredder, ingest, embed, and write manifest.
            // Minimal implementation: clone git URLs, attempt to run shredder and nu-ingest using available binaries.
            // 1) Clone if input looks like a git URL
            let mut source_path = input.clone();
            if input.starts_with("http://") || input.starts_with("https://") {
                let name = input
                    .rsplit('/')
                    .next()
                    .unwrap_or("source")
                    .replace(".", "-")
                    .replace(":", "-");
                let dest = format!("{}/sources/{}", out_dir, name);
                let _ = std::process::Command::new("git")
                    .args(["clone", &input, &dest])
                    .status();
                source_path = dest;
            }

            // 2) Run shredder (try built binary then cargo run)
            // 2) Run shredder per-markdown file (if source_path is a dir)
            let chunks_dir = format!("{}/chunks", out_dir);
            let embedding_dir = format!("{}/embedding_input", out_dir);
            std::fs::create_dir_all(&chunks_dir).ok();
            std::fs::create_dir_all(&embedding_dir).ok();

            // Helper: walk source_path recursively for .md files
            fn collect_md_files<P: AsRef<std::path::Path>>(p: P) -> Vec<String> {
                let mut out = Vec::new();
                let root = p.as_ref();
                if root.is_file() {
                    if let Some(ext) = root.extension().and_then(|s| s.to_str()) {
                        if ext == "md" {
                            out.push(root.to_string_lossy().to_string());
                        }
                    }
                    return out;
                }

                let mut stack = vec![root.to_path_buf()];
                while let Some(dir) = stack.pop() {
                    if let Ok(entries) = std::fs::read_dir(&dir) {
                        for e in entries.flatten() {
                            let p = e.path();
                            if p.is_dir() {
                                stack.push(p);
                            } else if p.is_file() {
                                if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
                                    if ext == "md" {
                                        out.push(p.to_string_lossy().to_string());
                                    }
                                }
                            }
                        }
                    }
                }
                out
            }

            let md_files = collect_md_files(&source_path);

            // If nu is available, prefer calling nu-ingest.nu which handles validation and outputs
            if which::which("nu").is_ok() {
                // run nu-ingest.nu script
                let _ = std::process::Command::new("nu")
                    .args(["nu-ingest.nu", &source_path, "--out-dir", &out_dir])
                    .status();
            } else {
                // Fallback: run shredder (cargo run) for each markdown file and write chunks + embedding_input
                for md in &md_files {
                    let output = std::process::Command::new("cargo")
                        .args([
                            "run",
                            "--manifest-path",
                            "shredder/Cargo.toml",
                            "--quiet",
                            "--",
                            md,
                        ])
                        .output();

                    if let Ok(outp) = output {
                        if outp.status.success() {
                            let stdout = String::from_utf8_lossy(&outp.stdout).to_string();
                            let lines: Vec<&str> =
                                stdout.lines().filter(|l| !l.trim().is_empty()).collect();

                            if lines.is_empty() {
                                continue;
                            }

                            use std::path::Path;
                            let p = Path::new(md);
                            let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("document");
                            let chunks_path = format!("{}/{}.chunks.nuon", chunks_dir, stem);
                            let embedding_path =
                                format!("{}/{}.embedding_input.nuon", embedding_dir, stem);

                            // write chunks as NUON JSON array
                            if let Ok(mut f) = std::fs::File::create(&chunks_path) {
                                use std::io::Write;
                                let arr: Vec<serde_json::Value> = lines
                                    .iter()
                                    .filter_map(|l| {
                                        serde_json::from_str::<serde_json::Value>(l).ok()
                                    })
                                    .collect();
                                writeln!(f, "{}", serde_json::to_string_pretty(&arr).unwrap()).ok();
                            }

                            // build embedding_input JSONL from chunks' embedding_input fields
                            if let Ok(mut ef) = std::fs::File::create(&embedding_path) {
                                use std::io::Write;
                                let mut embeds: Vec<serde_json::Value> = Vec::new();
                                for l in &lines {
                                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(l) {
                                        if let Some(ei) = v.get("embedding_input") {
                                            let id =
                                                v.get("id").and_then(|x| x.as_str()).unwrap_or("");
                                            let record = serde_json::json!({"id": id, "text": ei});
                                            embeds.push(record);
                                        }
                                    }
                                }
                                writeln!(ef, "{}", serde_json::to_string_pretty(&embeds).unwrap())
                                    .ok();
                            }
                        }
                    }
                }
            }

            // 3) Run nu-ingest.nu via nu if available
            if which::which("nu").is_ok() {
                let _ = std::process::Command::new("nu")
                    .args(["nu-ingest.nu", &source_path, "--out-dir", &out_dir])
                    .status();
            } else {
                eprintln!("nu binary not found; skipping nu-ingest step. Run nu-ingest manually when nu is available.");
            }

            // 4) Run embed runner on embedding_input files if present
            let embedding_dir = format!("{}/embedding_input", out_dir);
            if std::path::Path::new(&embedding_dir).exists() {
                if let Ok(entries) = std::fs::read_dir(&embedding_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                            if ext == "msgpack" || ext == "nuon" {
                                let stem =
                                    path.file_stem().and_then(|s| s.to_str()).unwrap_or("out");
                                let out_file = format!("{}/{}.embeddings.msgpack", out_dir, stem);
                                let embed_bin = "crates/nu_plugin_rag/target/debug/embed_runner";
                                if std::path::Path::new(&embed_bin).exists() {
                                    let _ = std::process::Command::new(embed_bin)
                                        .args([
                                            "--input",
                                            path.to_str().unwrap(),
                                            "--output",
                                            &out_file,
                                        ])
                                        .status();
                                }
                            }
                        }
                    }
                }
            }

            let manifest = json!({"status":"ok", "input": input, "out_dir": out_dir});
            println!("{}", manifest);
        }
        Commands::Status { out_dir } => {
            let resp = json!({"status":"ok", "action":"status", "out_dir": out_dir});
            println!("{}", resp);
        }
    }

    Ok(())
}
