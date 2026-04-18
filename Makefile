SHELL := /bin/bash
.PHONY: prep build kuzu-import

prep:
	@nu scripts/prep-nu-rag.nu

build:
	@nu -c "scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git"

kuzu-import:
	@nu scripts/kuzu-import.nu --plan build/rag/nu-docs/kuzu-plan.json --execute-kuzu

plugin-build:
	@cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

embed-example:
	@./crates/nu_plugin_rag/target/debug/embed_runner --input examples/embedding_input_example.jsonl --output build/embeddings_example.jsonl --dim 16
