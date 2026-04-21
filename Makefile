SHELL := /bin/bash
.PHONY: prep build

prep:
	@nu scripts/prep-nu-rag.nu

build:
	@nu -c "scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git"


plugin-build:
	@cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

embed-example:
	# Example invocation updated for MessagePack-first policy. Use .msgpack input/output when possible.
	@./crates/nu_plugin_rag/target/debug/embed_runner --input examples/embedding_input_example.msgpack --output build/embeddings_example.msgpack --dim 16
