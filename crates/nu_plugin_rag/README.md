nu_plugin_rag (Rust)
---------------------

Purpose
 - Provide a small, efficient Rust binary for indexing and brute-force similarity search.
 - Keep heavy numeric / binary responsibilities in compiled Rust for correctness and performance.

Included tool
 - flat_index: build and query a flat JSON index using MessagePack vector inputs.

When to use Rust vs Nushell
 - Nushell: orchestration, structured data manipulation, streaming IO, calling external services.
 - Rust: binary-safe MessagePack handling, large-array numeric operations (vector storage, dot products), indexing.

Environment
 - EMBEDDING_REMOTE_URL: URL for the remote embedding service.
 - EMBEDDING_MODEL: model to request for embeddings.
 - EMBEDDING_API_KEY: optional API key.

Usage example
  - Build index (from msgpack file created by embed-and-stream.nu):
      cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
      ./target/debug/flat_index query <index.json> 5 "example query"

Shredder tokenizer usage
 - The shredder binary supports tokenizer-aware splitting via the tokenizers + text-splitter crates.
 - Recommended for Mixedbread (mxbai-embed-large-v1) models to ensure chunk token counts match the remote model's tokenizer.
 - Example (prefer this when using Mixedbread remote embeddings):
     SHREDDER_TOKENIZER=mixedbread-ai/mxbai-embed-large-v1 ./target/debug/shredder README.md --max-tokens 512 --overlap-tokens 64 --prepend-passage > out.msgpack

 - If tokenizer loading fails or network is unavailable, shredder will fall back to a safe char-based chunker and log the fallback to stderr.
