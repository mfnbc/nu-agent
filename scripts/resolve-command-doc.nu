# Nushell shim: resolve-command-doc
# Usage: nu scripts/resolve-command-doc.nu --name "command"

export def main [--name: string] {
    if (($name | default "") == "") {
        error make { msg: "Missing required --name argument" }
    }

    let q = $"MATCH (c:Command {{name: '{($name)}'}}) OPTIONAL MATCH (c)-[:DESCRIBED_IN]->(ch:Chunk) RETURN c.signature AS signature, ch.data.content AS description, ch.data.code_blocks AS examples"

    if (which kuzu-query | success) {
        try {
            let rows = (kuzu-query $q | from json)
            let signature = ($rows | first 1 | get signature) | default ""
            let descriptions = ($rows | where description != null | get description) | default []
            let examples = ($rows | where examples != null | get examples) | default []

            return { status: "ok", backend: "kuzu", name: $name, signature: $signature, description: $descriptions, examples: $examples }
        } catch { |err|
            # if kuzu-query fails, fallthrough to JSON fallback
            null
        }
    }

    # Fallback: use command_map.json + data/nu_docs_vectors.jsonl
    if not ("data/command_map.json" | path exists) {
        return { status: "error", message: "command_map.json not found; run scripts/ingest-docs.nu first", code: "missing_command_map" }
    }

    let cmap = (open data/command_map.json | from json)
    let key = ($name | str downcase)

    if not ((cmap | has $key)) {
        # Build simple fuzzy suggestions: prefer substring matches then length proximity
        let keys = (cmap | keys)

        # Prefer compiled fuzzy binary for deterministic, faster suggestions
        let fuzzy_bin = "crates/nu_fuzzy_match/target/debug/nu_fuzzy_match"
        let run_cmd = if ("$fuzzy_bin" | path exists) {
            ^$fuzzy_bin --query $name --map-path data/command_map.json --top 3
        } else {
            # Fallback to cargo run
            ^cargo run --manifest-path crates/nu_fuzzy_match/Cargo.toml -- --query $name --map-path data/command_map.json --top 3
        }

        let out = (do { $run_cmd } | complete)
        if $out.exit_code != 0 {
            # Fallback: use substring suggestions as a last resort
            let suggestions = (cmap | keys | where { ($it | str downcase) =~ ($key | str downcase) } | first 3 | each { { name: (cmap | get $it | get display), key: $it, score: 0 } })
            return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions, note: "fuzzy binary failed" }
        }

        let parsed = try { ($out.stdout | from json) } catch { null }
        if $parsed == null {
            let suggestions = (cmap | keys | where { ($it | str downcase) =~ ($key | str downcase) } | first 3 | each { { name: (cmap | get $it | get display), key: $it, score: 0 } })
            return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions, note: "fuzzy binary produced invalid JSON" }
        }

        # Map binary output into our suggestion shape
        let suggestions = ($parsed | each { |row| { name: ($row.display? | default $row.key), key: $row.key, score: $row.score } })
        return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions }
    }

    let chunk_id = (cmap | get $key | get id)

    if not ("data/nu_docs_vectors.jsonl" | path exists) {
        return { status: "error", message: "nu_docs_vectors.jsonl not found; run scripts/ingest-docs.nu first", code: "missing_vectors" }
    }

    let rows = (open --raw data/nu_docs_vectors.jsonl | lines | where { ($it | str trim) != "" } | each { $it | from json })
    let hit = (rows | where { ($it.id? | default "") == $chunk_id } | first)

    if ($hit == null) {
        return { status: "error", message: "Mapped chunk id not found in vectors JSONL", chunk_id: $chunk_id }
    }

    let sig = ($hit.signature? | default null)
    let desc = (if ($hit.data? | default null) != null { ($hit.data.content? | default null) } else { ($hit.text? | default null) })
    let exs = ($hit.data? | default {} | get code_blocks | default [])

    { status: "ok", backend: "command_map", name: $name, signature: $sig, description: $desc, examples: $exs }
}
