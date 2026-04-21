use anyhow::Result;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Embed runner: generates embeddings via remote embedding service and writes MessagePack output"
)]
struct Args {
    /// Input corpus (.nuon preferred)
    #[arg(long)]
    input: String,

    /// Optional output path for MessagePack fallback. If SurrealDB is unavailable
    /// the runner will write embeddings to this path as a single MessagePack array.
    #[arg(long, default_value = "build/nu_ingest/embeddings.msgpack")]
    output: String,

    /// Optional path to write the first produced embedding as a raw MessagePack
    /// array of floats. Useful for producing a query vector file for nu-search.
    #[arg(long)]
    vector_out: Option<String>,
    // (removed unused dim option to simplify the runner)
}

fn main() -> Result<()> {
    let args = Args::parse();
    // Delegate to library helper so tests can call the same logic directly.
    nu_plugin_rag::embed_and_write(&args.input, &args.output, args.vector_out.as_deref())?;
    Ok(())
}
