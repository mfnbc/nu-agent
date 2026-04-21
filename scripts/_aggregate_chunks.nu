#!/usr/bin/env nu
# Aggregate all per-file .chunks.msgpack into build/nu_ingest/chunks.msgpack
if not ("build/nu_ingest" | path exists) {
  echo "missing build/nu_ingest"; exit 1
}

let files = (ls build/nu_ingest | where name =~ '\.chunks.msgpack$' | get name)
if ($files | length) == 0 {
  echo "no .chunks.msgpack files found"; exit 1
}

let all = []
for f in $files {
  # open each file and from msgpack to get records, then append to all
  let recs = (open $("build/nu_ingest/$f") | from msgpack)
  if ($recs != []) { let all = ($all + $recs) }
}

# Persist the aggregated array as binary MessagePack
$all | to msgpack | save -f build/nu_ingest/chunks.msgpack
echo "wrote: (open build/nu_ingest/chunks.msgpack | from msgpack | length) chunks to build/nu_ingest/chunks.msgpack"
