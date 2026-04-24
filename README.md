# nu-agent

**A query tool for the self-describing-record world, and the bootstrapping core of a Nushell-native personal data ecosystem.**

nu-agent is to a Nushell-based personal data system what `psql` is to PostgreSQL — a client that takes a query and returns records. The difference is the query language: instead of SQL, nu-agent accepts a natural-language prompt plus a [contract](docs/CONTRACTS.md), routes it through an LLM, and emits JSON tool-calls that execute through Nushell. It is deliberately narrow (single record in, single validated result out), and narrow on purpose — the narrowness is what makes invocations composable.

## Core shape

```
(prompt + contract) → LLM → JSON tool-calls → Nushell execution → records
```

One invocation is one query. Batching, iteration, scheduling, and cross-invocation workflows happen *outside* nu-agent. See [docs/VISION.md](docs/VISION.md) for the ecosystem this enables and [docs/CONTRACTS.md](docs/CONTRACTS.md) for the full contract catalogue.

## Who it is for

- Developers building **wings** — domain-specific toolkits for personal data (workouts, ledger, chess, astronomy, reading, bible tokens, notes).
- People who want natural-language access to structured personal data without surrendering that data to opaque apps.
- Nushell users who want the LLM to participate in their shell as a disciplined query partner, not a chatbot.

nu-agent is **not** a general-purpose coding assistant. Its scope is Nushell + `nu_plugin` Rust crates, and its mandate is narrow queries and `.try`-preview code edits.

## Quickstart

```bash
# Build the Rust helpers (shredder, embed_runner, import_nu_docs, nu_plugin_rag).
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

# The CLI wrapper requires NU_AGENT_CHAT_URL as a guard. Any non-empty value works;
# the actual endpoint is currently hardcoded in llm.nu.
export NU_AGENT_CHAT_URL="http://127.0.0.1:1234/v1/chat/completions"

# Run a single-record enrichment.
./nu-agent \
  --task "annotate workout" \
  --record '{"exercise":"squat","reps":5}' \
  --schema '{"allowed":["label","notes"],"required":["label"],"non_null":["label"]}'
```

For the RAG pipeline over Markdown docs:

```bash
nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force
```

See [docs/DEVELOPER.md](docs/DEVELOPER.md) for the full build/run/test flow and [docs/RAG.md](docs/RAG.md) for the retrieval pipeline walkthrough.

## Configuration

The LLM endpoint URL, model name, request timeout, and reasoning-suppression flags are currently **hardcoded** as constants at the top of `llm.nu`. To point at a different endpoint or model, edit that file directly.

The CLI wrapper (`./nu-agent`) requires `NU_AGENT_CHAT_URL` to be set to any non-empty value as a guard against running without explicit configuration intent. The actual endpoint is in `llm.nu`; reconciling the two into a single deliberate configuration path is planned when env-var configurability returns.

## Documentation

- [**VISION.md**](docs/VISION.md) — the ecosystem north star: life-os, mansion and wings, three-layer federation.
- [**CONTRACTS.md**](docs/CONTRACTS.md) — the contract model, catalogue, and system-prompt templates.
- [**ARCHITECTURE.md**](docs/ARCHITECTURE.md) — technical layers: thin client, contract adapters, Operator runtime, tool registry, RAG plugin, shredder.
- [**STATUS.md**](docs/STATUS.md) — what is implemented, what is in flight, known warts.
- [**RAG.md**](docs/RAG.md) — retrieval pipeline walkthrough.
- [**DEVELOPER.md**](docs/DEVELOPER.md) — build, run, test.
- [**RULES.md**](RULES.md) — hard invariants that apply to every contract.
