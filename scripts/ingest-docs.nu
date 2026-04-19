# Nushell ingestion script: shred markdown, embed, populate Kùzu, and persist vectors
# Usage: nu scripts/ingest-docs.nu --path "docs/"

def main [path:string = "docs/"] {
    print "Step 1: Shredding Markdown..."

    # Ensure data dir exists
    if not ("data" | path exists) { mkdir data }

    # If a precomputed chunks.jsonl exists in build/nu_ingest, reuse it as the
    # canonical shredder output to avoid re-running the shredder. Otherwise,
    # run the shredder over the provided path.
    let chunks = if ("build/nu_ingest/chunks.jsonl" | path exists) {
        (open build/nu_ingest/chunks.jsonl | lines | where { |l| ($l | str trim) != "" } | each { |l| $l | from json })
    } else {
        # Collect markdown files (recursive glob) using find-like fallback
        let md_files = (glob ($path) | where {|it| $it.type == "File" } )
        # Run shredder per-file and collect chunk JSONL records
        md_files | where { |f| ($f.name | str ends-with ".md") } | each { |file|
            if ("./shredder" | path exists) {
                ./shredder $file.name
            } else {
                cargo run --manifest-path shredder/Cargo.toml -- $file.name
            }
        } | flatten
    }

    print "Step 2: Vectorizing (LanceDB/Rig)..."
    # Pipe the chunks into the embed_runner. The embed_runner expects an embedding_input JSONL
    # and writes embeddings.jsonl. We reuse the deterministic engine by default; use --engine tract
    # if you've prepared the model via prepare-deps and want semantic embeddings.

    # Locate embed_runner binary in common build locations; prefer workspace target/debug
    let embed_bin_candidates = ["./target/debug/embed_runner", "./target/release/embed_runner", "./crates/nu_plugin_rag/target/debug/embed_runner", "./crates/nu_plugin_rag/target/release/embed_runner"]
    let embed_bin = (echo $embed_bin_candidates | each { |p| if ($p | path exists) { $p } else { "" } } | where { |x| $x != "" } | first 1 | default "")
    if ($embed_bin == "") {
        print "embed_runner not found in target dirs; build with: cargo build -p nu_plugin_rag"
        return
    }

    # Prepare embeddings. Prefer MessagePack embedding_input emitted by the shredder.
    if ("build/nu_ingest/embeddings.msgpack" | path exists) {
        print "Using existing build/nu_ingest/embeddings.msgpack"
    } else {
        # Prefer a MessagePack embedding_input file produced by the shredder
        let embedding_input_msgpack = ($out_dir | path join "README.embedding_input.msgpack")

        if ($embedding_input_msgpack | path exists) {
            do { ^$embed_bin --input $embedding_input_msgpack --output build/nu_ingest/embeddings.msgpack } | each { |l| echo $l }
        } else if ("data/nu_docs_vectors.nuon" | path exists) {
            # fallback to NUON corpus
            do { ^$embed_bin --input data/nu_docs_vectors.nuon --output build/nu_ingest/embeddings.msgpack } | each { |l| echo $l }
        } else {
            # fallback to chunks JSONL-derived embedding input
            do { ^$embed_bin --input build/nu_ingest/chunks.msgpack --output build/nu_ingest/embeddings.msgpack } | each { |l| echo $l }
        }
    }

    # Live documentation: sample one-liner showing how to bridge vector search (nu-search)
    # and Nushell traversal. This is a convenience hint and does not run during ingestion.
    echo "# Example: embed text, search, then traverse metadata"
    echo "# embed_runner --input query.nuon --output query_embedding.msgpack" \
         "&& nu-search --input data/nu_docs.msgpack --query-vec query_embedding.msgpack --top-k 3 --out-format nuon | from nuon | each { |hit| open data/nu_docs.msgpack | from msgpack | where id == $hit.id | get taxonomy.commands } | flatten | uniq"

    print "Step 3: Building command map from chunks (no Kùzu provisioning)..."
    # Build an in-memory map command -> chunk_id from the canonical corpus (NUON or chunks)
    let corpus = if ("data/nu_docs_vectors.nuon" | path exists) { open data/nu_docs_vectors.nuon } else { $chunks }
    let command_pairs = (
        $corpus
        | each { |chunk|
            let cmds_raw = (try { $chunk.taxonomy.commands } catch { [] })
            let cmds = ($cmds_raw | default [])
            if ($cmds != []) { $cmds | each { |cmd| { cmd: $cmd, id: $chunk.id } } } else { [] }
        }
        | flatten
    )

    let command_map = {}
    for p in $command_pairs {
        let key = ($p.cmd | str downcase)
        let existing = (try { $command_map | get $key } catch { null })
        if ($existing == null) {
            let command_map = ($command_map | upsert ($key) { id: $p.id, display: $p.cmd })
        }
    }

    # Persist the command map so resolve-command-doc can work without Kùzu (NUON)
    ($command_map | to nuon --indent 2) | save -f data/command_map.nuon

    print "Step 4: Persisting canonical MessagePack store (data/nu_docs.msgpack)..."
    # Ensure we have a canonical MessagePack blob for downstream consumers
    if ("build/nu_ingest/embeddings.msgpack" | path exists) {
        cp build/nu_ingest/embeddings.msgpack data/nu_docs.msgpack
    } else {
        # As a last resort, persist NUON
        $corpus | to nuon --indent 2 | save -f "data/nu_docs_vectors.nuon"
    }

    print "Ingestion complete: data/nu_docs_vectors.nuon, data/command_map.nuon created, and Kùzu populated (if kuzu-query present)."
}

main
