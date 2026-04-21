#!/usr/bin/env nu
# Aggregate all per-file .chunks.msgpack into build/nu_ingest/chunks.msgpack
def main [dir: path = "build/nu_ingest"] {
  if not ($dir | path exists) {
    print $"Directory not found: ($dir)"; exit 1
  }

  print "Aggregating MessagePack chunks..."

  # 1. List files, 2. Open and decode, 3. Flatten into one list
  # Build the full list of chunk records, collecting the streamed records into a single list
  let all_chunks = (
    ls $dir
    | where name =~ '\\.chunks.msgpack$'
    | each { |r| open $"($r.name)" | from msgpack }
    | flatten
    | wrap items
    | get items
  )

  # 4. Save as binary MessagePack for the machine
  $all_chunks | to msgpack | save -f $"($dir)/chunks.msgpack"

  # 5. Save a NUON dump for human inspection (pretty)
  $all_chunks | to nuon --indent 2 | save -f data/nu_docs_vectors.nuon

  let n = ($all_chunks | length)
  print $"Aggregated ($n) chunks into ($dir)/chunks.msgpack and data/nu_docs_vectors.nuon"
}

main
