# Nushell ingestion script: shred markdown, embed, populate Kùzu, and persist vectors
# Usage: nu scripts/ingest-docs.nu --path "docs/"

def main [path:string = "docs/"] {
    print "Step 1: Shredding Markdown..."

    # Collect markdown files (recursive glob)
    let md_files = (ls ($path)/**/*.md 2>/dev/null)

    # Ensure data dir exists
    if not ("data" | path exists) { mkdir data }

    # Run shredder per-file and collect chunk JSONL records
    let chunks = $md_files | each { |file|
        # prefer a built shredder binary if present
        if ("./shredder" | path exists) {
            ./shredder $file.name
        } else {
            # fallback: cargo run shredder crate
            cargo run --manifest-path shredder/Cargo.toml -- $file.name
        }
    } | flatten

    print "Step 2: Vectorizing (LanceDB/Rig)..."
    # Pipe the chunks into the embed_runner. The embed_runner expects an embedding_input JSONL
    # and writes embeddings.jsonl. We reuse the deterministic engine by default; use --engine tract
    # if you've prepared the model via prepare-deps and want semantic embeddings.

    let embed_bin = "./crates/nu_plugin_rag/target/debug/embed_runner"
    if (not ($embed_bin | path exists)) {
        print "embed_runner not found at ($embed_bin). Build with: cargo build -p nu_plugin_rag"
        return
    }

    # Convert chunks to JSONL and run embed_runner. This assumes each chunk has fields {id, text, taxonomy}
    let embedded = ($chunks | to json | run { $embed_bin --input - --output - --engine deterministic --dim 128 } | from json)

    print "Step 3: Populating Kùzu (Exact Matches) and building command map..."
    # Build an in-memory map command -> chunk_id while also populating Kùzu if present
    let command_pairs = (
        $embedded
        | each { |chunk|
            if ($chunk.taxonomy.commands | is-not-empty) {
                $chunk.taxonomy.commands | each { |cmd| { cmd: $cmd, id: $chunk.id } }
            } else { [] }
        }
        | flatten
    )

    # Populate Kùzu if available and build command_map from pairs (first-seen wins)
    let command_map = (
        $command_pairs
        | reduce -f {} { |item, acc|
            if (acc | has $item.cmd) {
                acc
            } else {
                let _ = if (which kuzu-query | success) { kuzu-query ($"MERGE (c:Command {{name: '{($item.cmd)}'}})\nMERGE (ch:Chunk {{id: '{($item.id)}'}})\nMERGE (c)-[:DESCRIBED_IN]->(ch)") } else { null }
                let key = ($item.cmd | str downcase)
                acc | upsert ($key) { id: $item.id, display: $item.cmd }
            }
        }
    )

    # Persist the command map so resolve-command-doc can work without Kùzu
    (command_map | to json) | save -f data/command_map.json

    print "Step 4: Persisting LanceDB vectors (JSONL)..."
    # Persist vectors and metadata for downstream retrieval (Rig/Lance ingestion can be opt-in later)
    $embedded | save -f "data/nu_docs_vectors.jsonl"

    print "Ingestion complete: data/nu_docs_vectors.jsonl, data/command_map.json created, and Kùzu populated (if kuzu-query present)."
}

main
