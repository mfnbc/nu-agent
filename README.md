# nu-agent

A Nushell-native query tool that routes a prompt through an LLM under the discipline of a **contract** — a TOML file declaring the LLM's role, action scope, and (optionally) a corpus to retrieve grounding context from.

Ships with one contract: the **Nushell Data Architect** — a domain expert in Nushell idioms and `nu_plugin` Rust. Grounded by RAG over the Nushell documentation; calls a search tool to verify answers against current docs rather than relying on training-data memory.

## Quickstart

```nu
# 1. Build the Rust plugin
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

# 2. Register the plugin (one-time)
plugin add ./crates/nu_plugin_rag/target/debug/nu_plugin_rag
plugin use rag

# 3. Clone the Nushell documentation source
mkdir external
git clone https://github.com/nushell/nushell.github.io.git external/nushell.github.io

# 4. Pre-download the mxbai tokenizer (one-time; tokenizers 0.19 can't fetch from HF directly)
mkdir tokenizers
http get https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1/resolve/main/tokenizer.json | save tokenizers/mxbai.json

# 5. Build the corpus (one-time, ~10-30 minutes)
# `where` filters out translated docs (any path segment matching a BCP-47 language tag)
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
  → engine reads the contract
  → for verb=Investigate: hands the LLM a search tool, runs the tool-call loop
  → for verb=Consult:    pre-retrieves top-k chunks, single LLM call
  → final prose response
```

Each invocation is one query. The plugin commands (`rag shred`, `rag embed`, `rag similarity`) are stateless transforms — Rust does the heavy compute, nu does I/O and orchestration. Persistence is nu's job (`open`/`save` over msgpack).

## Configuration

All knobs live in TOML, resolved through a four-layer cascade (highest priority first):

1. `NU_AGENT_*` env vars — leaf-scalar overrides (`NU_AGENT_CHAT_URL`, `NU_AGENT_CHAT_MODEL`, `NU_AGENT_EMBEDDING_URL`, `NU_AGENT_EMBEDDING_MODEL`, `NU_AGENT_TOKENIZER_PATH`, `NU_AGENT_DEFAULT_CONTRACT`)
2. `./config.local.toml` — repo-local override, gitignored
3. `~/.config/nu-agent/config.toml` — user-global, XDG-style
4. `./config.toml` — committed defaults

Relative paths in any config file resolve against that file's directory, so a tokenizer at `tokenizers/mxbai.json` in `~/.config/nu-agent/config.toml` lives at `~/.config/nu-agent/tokenizers/mxbai.json`, while the same line in `./config.toml` lives at `<repo>/tokenizers/mxbai.json`.

The committed `config.toml` defaults to a local LM Studio endpoint (`http://172.19.224.1:1234/v1/{chat,embeddings}`); edit `config.local.toml` for your machine.

## Documentation

- [**docs/VISION.md**](docs/VISION.md) — the ecosystem this serves.
- [**docs/CONTRACTS.md**](docs/CONTRACTS.md) — the two-dimensional contract model.
- [**docs/STATUS.md**](docs/STATUS.md) — current state and known warts.
