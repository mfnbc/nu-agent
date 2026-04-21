# Nushell shim: resolve-command-doc
# Usage: nu scripts/resolve-command-doc.nu --name "command"

export def main [--name: string] {
    if (($name | default "") == "") {
        error make { msg: "Missing required --name argument" }
    }

    # Build the MATCH query without using Nushell's ${} interpolation with braces
    # Escape single quotes in the provided name to avoid breaking the query string
    let safe_name = ($name | str replace "'" "\\'")
    let q = ("MATCH (c:Command {name: '" + $safe_name + "'}) OPTIONAL MATCH (c)-[:DESCRIBED_IN]->(ch:Chunk) RETURN c.signature AS signature, ch.data.content AS description, ch.data.code_blocks AS examples")

    # Note: Kùzu integration removed. Always use the local command_map / corpus fallback.

    # Fallback: use command_map.nuon + (data/nu_docs_vectors.nuon or data/nu_docs.msgpack)
    if not ("data/command_map.nuon" | path exists) {
        return { status: "error", message: "data/command_map.nuon not found; run scripts/ingest-docs.nu first", code: "missing_command_map" }
    }

    # Read the command map (NUON) as a record
    let cmap = (open data/command_map.nuon)
    let key = ($name | str downcase)

    # Try to get the entry for this key from the command map; use try to avoid errors
    let entry = try { ($cmap | get $key) } catch { null }

    if ($entry == null) {
        # Build simple fuzzy suggestions: prefer substring matches then length proximity
        let keys = (try { ($cmap | keys) } catch { [] })

        # Prefer compiled fuzzy binary for deterministic, faster suggestions
        let fuzzy_bin = "crates/nu_fuzzy_match/target/debug/nu_fuzzy_match"
        let run_cmd = if ("$fuzzy_bin" | path exists) {
            ^$fuzzy_bin --query $name --map-path data/command_map.nuon --top 3
        } else {
            # Fallback to cargo run
            ^cargo run --manifest-path crates/nu_fuzzy_match/Cargo.toml -- --query $name --map-path data/command_map.nuon --top 3
        }

        let out = try { (do { $run_cmd } | complete) } catch { null }
        if ($out == null) {
            # Fallback: use substring suggestions as a last resort
            let suggestions = (try { ($cmap | keys | where { ($it | str downcase) =~ ($key | str downcase) } | first 3 | each { { name: ($cmap | get $it | get display), key: $it, score: 0 } }) } catch { [] })
            return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions, note: "fuzzy binary failed to execute" }
        }

        let parsed = try { ($out.stdout | from json) } catch { null }
        if $parsed == null {
            let suggestions = (try { ($cmap | keys | where { ($it | str downcase) =~ ($key | str downcase) } | first 3 | each { { name: ($cmap | get $it | get display), key: $it, score: 0 } }) } catch { [] })
            return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions, note: "fuzzy binary produced invalid JSON" }
        }

        # Map binary output into our suggestion shape
        let suggestions = ($parsed | each { |row| { name: ($row.display? | default $row.key), key: $row.key, score: $row.score } })
        return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions }
    }

    let chunk_id = ($entry | get id)

    # Prefer NUON corpus for robust Nushell-native parsing; if NUON is missing fall back to MessagePack
    let use_msgpack = false
    if ("data/nu_docs_vectors.nuon" | path exists) {
        let rows = (open data/nu_docs_vectors.nuon)
        let hit = null
        for r in $rows {
            if (($r.id? | default "") == $chunk_id) { let hit = $r; break }
        }
    } else if ("data/nu_docs.msgpack" | path exists) {
        # Read the MessagePack canonical store
        let rows = (open data/nu_docs.msgpack | from msgpack)
        let hit = null
        for r in $rows {
            if (($r.id? | default "") == $chunk_id) { let hit = $r; break }
        }
        let use_msgpack = true
    } else {
        return { status: "error", message: "No corpus found (data/nu_docs_vectors.nuon or data/nu_docs.msgpack); run scripts/ingest-docs.nu first", code: "missing_corpus" }
    }

    if ($hit == null) {
        # Best-effort: search for mentions of the command in text/embedding_input/data.code_blocks
        let name_lc = ($name | str downcase)
        let alt_hit = null
        let rows2 = if (use_msgpack) { (open data/nu_docs.msgpack | from msgpack) } else { (open data/nu_docs_vectors.nuon) }
        for r2 in $rows2 {
            let txt = (($r2.text? | default "") | str downcase)
            let emb = (($r2.embedding_input? | default "") | str downcase)
            let data_content = (($r2.data? | default {} | get content | default "") | str downcase)
            let combined = ($txt + "\n" + $emb + "\n" + $data_content)
            if ($combined =~ $name_lc) { let alt_hit = $r2; break }
        }

        if ($alt_hit == null) {
            return { status: "error", message: "Mapped chunk id not found in corpus and no alternative match", chunk_id: $chunk_id }
        }

        let hit = $alt_hit
    }

    let sig = ($hit.signature? | default null)
    let desc = (if ($hit.data? | default null) != null { ($hit.data.content? | default null) } else { ($hit.text? | default null) })
    let exs = ($hit.data? | default {} | get code_blocks | default [])

    { status: "ok", backend: "command_map", name: $name, signature: $sig, description: $desc, examples: $exs }
}
