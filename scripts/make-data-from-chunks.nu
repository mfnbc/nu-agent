#!/usr/bin/env nu
# Convert shredder output into data/ files used by the nushell agent
def main [] {
  # ensure directories
  if not ("data" | path exists) { mkdir data }
  if not ("build/nu_ingest" | path exists) { echo "missing build/nu_ingest; run shredder first"; return }

  # Prefer binary MessagePack shredder output if present
  let chunks = if ("build/nu_ingest/chunks.msgpack" | path exists) { (open --raw build/nu_ingest/chunks.msgpack | from msgpack) } else if ("build/nu_ingest/chunks.nuon" | path exists) { (open build/nu_ingest/chunks.nuon | from nuon) } else { error make { msg: "No chunk corpus found; run shredder to produce build/nu_ingest/chunks.msgpack or chunks.nuon" } }

  # Persist chunks as the canonical binary MessagePack store and a NUON copy for Nushell-friendly reading
  $chunks | to msgpack | save -f data/nu_docs.msgpack
  $chunks | to nuon --indent 2 | save -f data/nu_docs_vectors.nuon

  # Build command_map: produce pairs (k,v) and reduce into a single record
  let command_pairs = (
    $chunks
    | where { |x| ($x.taxonomy.commands? | default []) != [] }
    | each { |chunk|
        let cmds = (try { $chunk.taxonomy.commands } catch { [] })
        if ($cmds != []) { $cmds | each { |cmd| { k: $cmd, v: $chunk.id } } } else { [] }
      }
    | flatten
  )

  # Use reduce to build a record mapping lowercase command -> { id, display }
  let command_map = (
    $command_pairs
    | reduce --fold {} { |pair, acc|
        let key = ($pair.k | str downcase)
        let existing = (try { $acc | get $key } catch { null })
        if ($existing == null) { $acc | upsert $key { id: $pair.v, display: $pair.k } } else { $acc }
      }
  )

  # Persist command map as NUON for Nushell-native consumption
  ($command_map | to nuon --indent 2) | save -f data/command_map.nuon

  # Produce embedding_input NUON (canonical) and MessagePack/JSONL outputs for embed_runner
  let embed_input = ($chunks | each { |rec| if ( ($rec.embedding_input? | default null) != null) { { id: $rec.id, text: $rec.embedding_input } } } | where { |x| $x != null })
  # Persist canonical NUON embedding input
  $embed_input | to nuon --indent 2 | save -f build/nu_ingest/embedding_input.nuon
  # Also emit MessagePack embedding_input for binary-first consumers
  $embed_input | to msgpack | save -f build/nu_ingest/embedding_input.msgpack

  echo "wrote: (open data/command_map.nuon | from nuon | keys | length) command_map entries (file: data/command_map.nuon)"
  echo "wrote: (open data/nu_docs_vectors.nuon | from nuon | length) doc vector entries (file: data/nu_docs_vectors.nuon)"
  echo "wrote: (open data/nu_docs.msgpack | from msgpack | length) doc vector entries (file: data/nu_docs.msgpack)"
  echo "wrote: (open build/nu_ingest/embedding_input.nuon | from nuon | length) embedding_input entries (file: build/nu_ingest/embedding_input.nuon)"
}

main
