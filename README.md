# nu-agent

A Nushell-native query tool that routes a prompt through an LLM under the discipline of a **contract** — a TOML file declaring the LLM's role, action scope, and (optionally) a corpus to retrieve grounding context from.

Ships with one contract: the **Nushell Data Architect** — a Consult-action persona that synthesizes prose answers about Nushell idioms, plugin authoring, and structured data pipelines. Grounded by RAG over the Nushell documentation.

## Quickstart

```nu
# 1. Build the Rust plugin and helpers
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

# 2. Register the plugin (one-time setup)
plugin add ./crates/nu_plugin_rag/target/debug/nu_plugin_rag
plugin use rag

# 3. Clone the Nushell documentation corpus source
mkdir external
git clone https://github.com/nushell/nushell.github.io.git external/nushell.github.io

# 4. Pre-download the mxbai tokenizer (one-time)
# `tokenizers = 0.19` has a URL parser bug that prevents Tokenizer::from_pretrained
# from fetching from HuggingFace, so we load from a local file instead.
mkdir tokenizers
http get https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1/resolve/main/tokenizer.json | save tokenizers/mxbai.json

# 5. Build the corpus (one-time, takes 10-30 minutes)
# The where-clause filters out translated docs (zh-CN, de, fr, etc.) — any path
# segment that looks like a BCP-47 language tag.
mkdir data
(ls external/nushell.github.io/**/*.md
 | where { |f| not ($f.name =~ '/[a-z]{2}(-[A-Z]{2,3})?/') }
 | each { |f| open $f.name | rag shred --source $f.name --tokenizer-path tokenizers/mxbai.json }
 | flatten
 | rag embed --column embedding_input
 | save --force data/nu_docs.msgpack)

# 6. Ask the architect
./nu-agent --prompt "How do I find the highest disk usage files in Nushell?"
```

## How it works

```
prompt + contract.toml
  → engine.nu reads the contract
  → if corpus declared: rag embed prompt → rag similarity over corpus → top-k chunks
  → call-llm with [contract.system, retrieved-context, user prompt]
  → prose response
```

Each invocation is one query. Persistence is nu's job (`open`/`save` over msgpack). The plugin commands (`rag shred`, `rag embed`, `rag similarity`) are stateless transforms — Rust does the heavy compute, nu does the I/O and orchestration.

## Configuration

LLM endpoint, model, and timeout are hardcoded constants at the top of `llm.nu`. The default points at a local LAN endpoint. Edit `llm.nu` to change them.

The architect contract's corpus path and `retrieval_k` are in `contracts/architect.toml`.

## Documentation

- [**VISION.md**](docs/VISION.md) — the ecosystem this serves.
- [**CONTRACTS.md**](docs/CONTRACTS.md) — the two-dimensional contract model.
- [**STATUS.md**](docs/STATUS.md) — current implementation state and known warts.
- [**DEVELOPER.md**](docs/DEVELOPER.md) — build, run, smoke.
- [**RAG.md**](docs/RAG.md) — retrieval pipeline reference.
- [**RULES.md**](RULES.md) — hard invariants.
