**nu-agent** is a Nushell-native tool that uses LLMs as a structured interface for personal data. 

It accepts selection of a pre-determined *contract* which acts as a system prompt, a contract appropriate user prompt, and routes it to an LLM. The result is a validated, structured record according to the contract.

## Key traits:

One invocation is one query. Batching, iteration, scheduling, and cross-invocation workflows happen *outside* nu-agent. See [docs/VISION.md](docs/VISION.md) for the ecosystem this enables and [docs/CONTRACTS.md](docs/CONTRACTS.md) for the full contract catalogue.

## Quickstart

```nu
# Build the Rust helpers (shredder, embed_runner, nu_plugin_rag).
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

# Run a single-record enrichment. The LLM endpoint is hardcoded in llm.nu;
# default points at a local LAN endpoint.
(
  ./nu-agent
    --task "annotate workout"
    --record '{"exercise":"squat","reps":5}'
    --schema '{"allowed":["label","notes"],"required":["label"],"non_null":["label"]}'
)
```

For the RAG pipeline over Markdown docs:
[TODO: The LLM is assumed to need nushell command help most immediately, this should show how to git clone the nushell documentation and prepare a RAG for use in writing nushell code commands]
```nu
nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force
```

See [docs/DEVELOPER.md](docs/DEVELOPER.md) for the full build/run/test flow and [docs/RAG.md](docs/RAG.md) for the retrieval pipeline walkthrough.

## Configuration
[TODO: Create a "models" configuration json file. Each model should be given a set of designation tags to a contract, for instance...

embed: Indicates embedding models (e.g., sentence-transformers). 
vision: For models handling images (e.g., ViT, CLIP).
tool: Suggests the model can call or use external tools (e.g., function-calling LLMs). 
reasoning: Implies strong logical or chain-of-thought reasoning (e.g., models trained on math/code). 
text2text-generation: For models that convert input text to output text (e.g., translation, summarization). 
conversational: Models designed for dialogue. 
audio, speech: For speech recognition or audio generation.
multimodal: Models handling multiple data types (e.g., text and image). 
llm: General tag for large language models. 
diffusers: For diffusion models used in image generation.

"tool" model, or "vision" model, or "embedding" model, in the style of the huggingface repository. It should also be given a rating of "common", "rare", "epic", "legendary" to denote the relative strength of that model and associated greater cost, and be designated as shiney to denote in their classification they are better than others. RESEARCH: Is there a way to just get the huggingface tags for each model if it is simply named in the config?]

The LLM endpoint URL, model name, request timeout, and reasoning-suppression flags are currently **hardcoded** as constants at the top of `llm.nu`. The default points at a local LAN endpoint. To use a different endpoint or model, edit `llm.nu` directly.

## Documentation

- [**VISION.md**](docs/VISION.md) — the ecosystem north star: life-os, mansion and wings, three-layer federation.
- [**CONTRACTS.md**](docs/CONTRACTS.md) — the contract model, catalogue, and system-prompt templates.
- [**ARCHITECTURE.md**](docs/ARCHITECTURE.md) — technical layers: thin client, contract adapters, Operator runtime, tool registry, RAG plugin, shredder.
- [**STATUS.md**](docs/STATUS.md) — what is implemented, what is in flight, known warts.
- [**RAG.md**](docs/RAG.md) — retrieval pipeline walkthrough.
- [**DEVELOPER.md**](docs/DEVELOPER.md) — build, run, test.
- [**RULES.md**](RULES.md) — hard invariants that apply to every contract.
