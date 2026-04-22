nu_plugin_rag (Rust)
---------------------

Purpose
 - Provide a small, efficient Rust binary for indexing and brute-force similarity search.
 - Keep heavy numeric / binary responsibilities in compiled Rust for correctness and performance.

Included tool
 - flat_index: build and query a flat JSON index using MessagePack vector inputs.

When to use Rust vs Nushell
- Nushell: orchestration, structured data manipulation, streaming IO, calling external services.
- Rust: binary-safe MessagePack handling, large-array numeric operations (vector storage, dot products), indexing, and the `rag` plugin runtime.

Environment
 - EMBEDDING_REMOTE_URL: URL for the remote embedding service.
 - EMBEDDING_MODEL: model to request for embeddings.
 - EMBEDDING_API_KEY: optional API key.

Usage (plugin)
- Build the plugin and register it with Nushell:
  cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
  plugin add nu_plugin_rag "/absolute/path/to/target/debug/nu_plugin_rag"

After registering the plugin you can use these commands from Nushell:
 - rag embed --mock|--url --column <col>
 - rag index-create <name>
 - rag index-add <name> [--batch-size N] [--quiet]
 - rag index-search <name> [--query-vector <vec>] [--mock] [--with-doc] [-f field]
 - rag index-save <name> --path <file>
 - rag index-load <name> --path <file>
 - rag index-list
 - rag index-remove <name>

Shredder tokenizer usage
 - The shredder binary supports tokenizer-aware splitting via the tokenizers + text-splitter crates.
 - Recommended for Mixedbread (mxbai-embed-large-v1) models to ensure chunk token counts match the remote model's tokenizer.
 - Example (prefer this when using Mixedbread remote embeddings):
     SHREDDER_TOKENIZER=mixedbread-ai/mxbai-embed-large-v1 ./target/debug/shredder README.md --max-tokens 512 --overlap-tokens 64 --prepend-passage > out.msgpack

 - If tokenizer loading fails or network is unavailable, shredder will fall back to a safe char-based chunker and log the fallback to stderr.
