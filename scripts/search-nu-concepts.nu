# Nushell shim: search-nu-concepts
# Usage: nu scripts/search-nu-concepts.nu --query "text"

export def main [--query: string, --limit: int = 0] {
    if (($query | default "") == "") {
        error make { msg: "Missing required --query argument" }
    }

    # Simple heuristic: case-insensitive substring match against the text field
    let q = ($query | str downcase)
    # Require NUON corpus
    if not ("data/nu_docs_vectors.nuon" | path exists) {
        error make { msg: "data/nu_docs_vectors.nuon or data/nu_docs.msgpack not found; run scripts/ingest-docs.nu first" }
    }

    let hits = (
        if ("data/nu_docs.msgpack" | path exists) { open data/nu_docs.msgpack | from msgpack } else { open data/nu_docs_vectors.nuon }
        | where { |row|
            let txt = ($row.text? | default "")
            let emb = ($row.embedding_input? | default "")
            let data_content = ($row.data? | default {} | get content | default "")
            let combined = (($txt + "\n" + $emb + "\n" + $data_content) | str downcase)
            $combined =~ $q
        }
    )
    let limited = if $limit > 0 { $hits | first $limit } else { $hits | first 5 }

    # Emit NUON structured output for consumers
    $limited | to nuon --indent 2
}

export def _main_unused [] { }
