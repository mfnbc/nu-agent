# Nushell shim: search-nu-concepts
# Usage: nu scripts/search-nu-concepts.nu --query "text"

export def main [--query: string, --limit: int = 0] {
    if (($query | default "") == "") {
        error make { msg: "Missing required --query argument" }
    }

    # If Lance/Rig not available, fallback to scanning data/nu_docs_vectors.jsonl
    if (not ("data/nu_docs_vectors.jsonl" | path exists)) {
        error make { msg: "data/nu_docs_vectors.jsonl not found; run scripts/ingest-docs.nu first" }
    }

    # Simple heuristic: case-insensitive substring match against the text field
    let q = ($query | str downcase)
    let hits = (
        open data/nu_docs_vectors.jsonl | from json |
        where ($it.text | str downcase) =~ $q
    )

    let limited = if $limit > 0 { $hits | first $limit } else { $hits | first 5 }

    $limited | to json
}

export def _main_unused [] { }
