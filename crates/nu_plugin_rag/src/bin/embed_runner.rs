use anyhow::Result;
use clap::Parser;
use nu_plugin_rag::read_embedding_input;
use serde_json::Value;
use std::fs;

// fastembed + surrealdb
use fastembed::text::TextEmbedding;
use surrealdb::engine::local::Db;
use surrealdb::opt::auth::Root;
use surrealdb::Surreal;

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Embed runner: generates embeddings with fastembed and persists to SurrealDB"
)]
struct Args {
    /// Input corpus (.nuon preferred)
    #[arg(long)]
    input: String,

    /// Optional output path for MessagePack fallback. If SurrealDB is unavailable
    /// the runner will write embeddings to this path as a single MessagePack array.
    #[arg(long, default_value = "build/nu_ingest/embeddings.msgpack")]
    output: String,
    // (removed unused dim option to simplify the runner)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Read corpus. Prefer NUON (JSON array). If input is msgpack, fall back to nu_agent_common helper.
    let mut chunks: Vec<Value> = Vec::new();
    if args.input.to_lowercase().ends_with(".nuon") {
        let s = fs::read_to_string(&args.input)?;
        chunks = serde_json::from_str(&s)?;
    } else if args.input.to_lowercase().ends_with(".msgpack") {
        // fallback: use read_embedding_input which returns id/text pairs for embedding only
        let recs = read_embedding_input(&args.input)?;
        for r in recs {
            let mut m = serde_json::Map::new();
            m.insert("id".to_string(), Value::String(r.id));
            m.insert("embedding_input".to_string(), Value::String(r.text));
            chunks.push(Value::Object(m));
        }
    } else {
        // Only .nuon and .msgpack are supported inputs for this runner. Fail fast to avoid
        // accidental ambiguous parsing branches.
        anyhow::bail!(
            "unsupported input format: {} (supported: .nuon, .msgpack)",
            args.input
        );
    }

    // Init fastembed model (sync). Use defaults — fastembed will pick a reasonable local model.
    let model = TextEmbedding::try_new(Default::default())?;

    // Attempt to start SurrealDB embedded. If that fails we will fall back to
    // writing a MessagePack file with embeddings. This keeps the runner portable.
    let mut use_surreal = true;
    let db_res = (|| async {
        let engine = Db::new("")?; // empty path -> in-memory/default
        let db = Surreal::new(engine).await?;
        db.signin(Root {
            username: "root",
            password: "root",
        })
        .await?;
        db.use_ns("nu_agent", "data").await?;
        Ok::<Surreal<Db>, anyhow::Error>(db)
    })
    .await;

    let db = match db_res {
        Ok(db) => Some(db),
        Err(e) => {
            eprintln!(
                "warning: SurrealDB init failed, falling back to msgpack output: {}",
                e
            );
            use_surreal = false;
            None
        }
    };

    // Ensure "chunk" table exists implicitly by inserting
    // Collect embeddings so we can write them out as a single MessagePack array if needed.
    let mut produced = Vec::with_capacity(chunks.len());

    for chunk in chunks.iter() {
        // Extract fields
        let id = chunk
            .get("id")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let path = chunk
            .get("path")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_default();
        let title = chunk
            .get("title")
            .and_then(Value::as_str)
            .map(|s| s.to_string())
            .unwrap_or_default();
        let heading_path = chunk.get("heading_path").cloned().unwrap_or(Value::Null);
        let text = chunk
            .get("embedding_input")
            .or_else(|| chunk.get("text"))
            .or_else(|| chunk.get("data"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_default();
        let commands = chunk
            .get("taxonomy")
            .and_then(|t| t.get("commands"))
            .cloned()
            .unwrap_or(Value::Array(vec![]));

        // Embed the text (single call)
        let embeddings = model.embed(vec![text.clone()], None)?;
        let embedding = embeddings.into_iter().next().unwrap_or_default();

        // Prepare insert object
        let mut obj = serde_json::Map::new();
        obj.insert("id".to_string(), Value::String(id.clone()));
        obj.insert("path".to_string(), Value::String(path));
        obj.insert("title".to_string(), Value::String(title));
        obj.insert("heading_path".to_string(), heading_path);
        obj.insert("text".to_string(), Value::String(text));
        obj.insert("commands".to_string(), commands);
        obj.insert("embedding".to_string(), serde_json::to_value(embedding)?);

        if use_surreal {
            // Use CREATE to insert a new chunk record. Let Surreal assign a Thing id.
            if let Some(ref db) = db {
                let _res = db.create("chunk").content(Value::Object(obj)).await?;
            }
        }

        // Always record the produced embedding for fallback output.
        let mut meta = serde_json::Map::new();
        meta.insert(
            "path".to_string(),
            chunk
                .get("path")
                .cloned()
                .unwrap_or(Value::String("".into())),
        );
        meta.insert(
            "title".to_string(),
            chunk
                .get("title")
                .cloned()
                .unwrap_or(Value::String("".into())),
        );
        meta.insert(
            "heading_path".to_string(),
            chunk.get("heading_path").cloned().unwrap_or(Value::Null),
        );

        let rec = serde_json::json!({
            "id": id.clone(),
            "text": text,
            "embedding": embedding,
            "metadata": Value::Object(meta),
        });
        produced.push(rec);
    }

    // If Surreal wasn't used, write out the produced embeddings as a MessagePack array
    if !use_surreal {
        // Ensure output dir exists
        if let Some(p) = std::path::Path::new(&args.output).parent() {
            std::fs::create_dir_all(p)?;
        }
        // Serialize produced Vec<Value> as MessagePack array
        let mut buf = Vec::new();
        rmp_serde::encode::write(&mut buf, &produced)?;
        std::fs::write(&args.output, buf)?;
        println!("wrote: {} (msgpack)", &args.output);
    } else {
        println!("wrote: (surreal)");
    }
    Ok(())
}
