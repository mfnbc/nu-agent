# Hydrate search hits by joining them to data/nu_docs.msgpack
# Usage: nu scripts/hydrate.nu build/rag/hits.json data/nu_docs.msgpack

def main [hits_path, docs_path] {
    # Read hits (JSON) and docs (MessagePack)
    let hits = (open --raw $hits_path | from json)
    let docs = (open $docs_path | from msgpack)

    # 1) Deduplicate while preserving order: keep first-seen hit per id
    let unique_hits = ($hits | uniq-by id)

    # 2) Hydrate: merge hit with the corresponding doc record
    $unique_hits | each { |hit|
        let doc_info = ($docs | where id == $hit.id | first)
        $hit | merge $doc_info
    } | select score id title path text
}
