# Nushell helper: rag-search
# Usage: nu scripts/rag-search.nu "how to filter tables" --limit 3

def main [query: string, --limit: int = 3] {
    # Create a temporary file for the query vector
    let tmp = (mktemp --suffix .msgpack)
    let tmp_path = ($tmp | get path)

    # 1) Generate query vector by embedding the query text via embed_runner
    # We emit a tiny NUON inline document to stdin and let embed_runner write the
    # query vector to the tmp file as MessagePack.
    let q = { embedding_input: $query } | to nuon
    echo $q | cargo run -p nu_plugin_rag --bin embed_runner -- --input - --output $tmp_path | each { |l| echo $l }

    # 2) Search with nu-search and hydrate results against data/nu_docs.msgpack
    let hits = (cargo run -p nu_plugin_rag --bin nu-search -- --input data/nu_docs.msgpack --query-vec $tmp_path --top-k $limit --out-format nuon | from nuon)

    # cleanup
    rm $tmp_path

    # 3) Hydrate: join ids back to the doc table and insert score
    $hits | each { |hit|
        open data/nu_docs.msgpack | from msgpack | where id == $hit.id | insert score $hit.score
    } | flatten
}

main
