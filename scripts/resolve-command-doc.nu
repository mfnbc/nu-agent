# Nushell shim: resolve-command-doc
# Usage: nu scripts/resolve-command-doc.nu --name "command"

export def main [--name: string] {
    if (($name | default "") == "") {
        error make { msg: "Missing required --name argument" }
    }

    # Fallback: use command_map.nuon + (data/nu_docs_vectors.nuon or data/nu_docs.msgpack)
    if not ("data/command_map.nuon" | path exists) {
        return { status: "error", message: "data/command_map.nuon not found; run scripts/ingest-docs.nu first", code: "missing_command_map" }
    }

    # Read the command map (prefer NUON, fall back to MessagePack)
    let cmap = if ("data/command_map.nuon" | path exists) {
        open data/command_map.nuon
    } else if ("data/command_map.msgpack" | path exists) {
        open --raw data/command_map.msgpack | from msgpack
    } else {
        return { status: "error", message: "command map not found; run scripts/ingest-docs.nu", code: "missing_command_map" }
    }

    let key = ($name | str downcase)
    let entry = try { ($cmap | get $key) } catch { null }

    if ($entry == null) {
        # Build fuzzy suggestions as a fallback
        let keys = (try { ($cmap | keys) } catch { [] })
        if (($keys | length) == 0) {
            return { status: "error", message: "Command not found", name: $name, suggestions: [] }
        }

        let suggestions = (
            $keys
            | where { |k| ($k | str contains $key) }
            | take 3
            | each { |k| { name: ($cmap | get $k | get display), key: $k, score: 0 } }
        )

        return { status: "error", message: "Command not found", name: $name, suggestions: $suggestions }
    }

    let chunk_id = ($entry | get id)

    # Locate the chunk in the materialised corpus
    let corpus = if ("data/nu_docs_vectors.nuon" | path exists) {
        open data/nu_docs_vectors.nuon
    } else if ("data/nu_docs.msgpack" | path exists) {
        open --raw data/nu_docs.msgpack | from msgpack
    } else {
        return { status: "error", message: "No corpus found (run scripts/ingest-docs.nu)", code: "missing_corpus" }
    }

    let hit = (
        $corpus
        | where { |row| (($row.id? | default "") == $chunk_id) }
        | first
        | default null
    )

    let chunk = if ($hit == null) {
        let name_lc = ($name | str downcase)
        (
            $corpus
            | where { |row|
                let txt = ($row.text? | default "" | str downcase)
                let emb = ($row.embedding_input? | default "" | str downcase)
                (($txt + "\n" + $emb) =~ $name_lc)
            }
            | first
            | default null
        )
    } else {
        $hit
    }

    if ($chunk == null) {
        return { status: "error", message: "Mapped chunk id not found in corpus", chunk_id: $chunk_id }
    }

    let desc = ($chunk.text? | default null)
    let exs = ($chunk.taxonomy? | default {} | get code_blocks? | default [])

    { status: "ok", backend: "command_map", name: $name, signature: null, description: $desc, examples: $exs }
}
