# Nushell helper: rag-search
# Usage: nu scripts/rag-search.nu "how to filter tables" --limit 3

def main [query: string, --limit: int = 3, --keep-temp: bool = $false] {
    # Create a temporary file for the query vector
    let tmp = (mktemp --suffix .msgpack)
    let tmp_path = ($tmp | get path)

    # 1) Generate query vector by embedding the query text via embed_runner.
    # Prefer a prebuilt binary for faster interactive runs; fall back to cargo run.
    let q = { embedding_input: $query } | to nuon
    let embed_bin = "./target/debug/embed_runner"
    let embed_cmd = if ("$embed_bin" | path exists) {
        ^$embed_bin --input - --output $tmp_path
    } else {
        ^cargo run -p nu_plugin_rag --bin embed_runner -- --input - --output $tmp_path
    }

    echo $q | do { $embed_cmd } | each { |l| echo $l }

    # 2) Search with nu-search and hydrate results against data/nu_docs.msgpack
    # Prefer prebuilt nu-search binary when available.
    let search_bin = "./target/debug/nu-search"
    let search_cmd = if ("$search_bin" | path exists) {
        ^$search_bin --input data/nu_docs.msgpack --query-vec $tmp_path --top-k $limit --out-format nuon
    } else {
        ^cargo run -p nu_plugin_rag --bin nu-search -- --input data/nu_docs.msgpack --query-vec $tmp_path --top-k $limit --out-format nuon
    }

    let hits = ($search_cmd | from nuon)

    # cleanup unless the caller requested we keep the temp file for debugging
    if not $keep_temp { rm $tmp_path }

    # 3) Hydrate: join ids back to the doc table and insert score
    $hits | each { |hit|
        open data/nu_docs.msgpack | from msgpack | where id == $hit.id | insert score $hit.score
    } | flatten
}

main
