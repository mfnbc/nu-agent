# Mass ingestion script for the nu_plugin_rag edifice
#
# This script will:
# - find all markdown files under external/nushell.github.io
# - stream them through rag shred (or a simplified inline shredding step), rag embed --mock,
#   and rag index-add nu_docs_full
# - print progress updates to stderr every N chunks
# - report final index stats using rag index-stats

let root = "external/nushell.github.io"

if (not (path exists $root)) {
    echo "Documentation root not found at: $root" > /dev/stderr
    exit 1
}

echo "Starting mass ingest from: $root" > /dev/stderr

# Adjustable batch and progress params
let progress_every = 500

# Stream files, open each as raw text and produce records { id, text }
ls $root **/*.md -r | get path | each { |p|
    let txt = (open --raw $p)
    #[ produce a record consumed by rag embed ]
    { id: ($p | path basename), text: $txt }
} 
| rag embed --mock --column text
| each -n 1 { |rec|
    # Each record is sent to index-add; we print progress periodically
    # Count is global across the pipeline by using a persistent variable
    env NU_INGEST_COUNT = (($env.NU_INGEST_COUNT? | default 0) + 1)
    if (($env.NU_INGEST_COUNT? | default 0) % $progress_every) == 0 { echo ($env.NU_INGEST_COUNT?) > /dev/stderr }
    $rec
}
| rag index-create nu_docs_full
| rag index-add nu_docs_full

# Final stats
echo "Ingest finished. Gathering index stats..." > /dev/stderr
let stats = (rag index-stats nu_docs_full)
echo $stats
