#!/usr/bin/env nu
# Convert shredder output into data/ files used by the nushell agent
def main [] {
  # ensure directories
  if not ("data" | path exists) { mkdir data }
  if not ("build/nu_ingest" | path exists) { echo "missing build/nu_ingest; run shredder first"; return }

  # Prefer binary MessagePack shredder output if present
  let chunks = if ("build/nu_ingest/chunks.msgpack" | path exists) { (open build/nu_ingest/chunks.msgpack | from msgpack) } else { (open build/nu_ingest/chunks.jsonl | lines | where { |l| ($l | str trim) != "" } | each { |l| $l | from json }) }

  # Persist chunks as the canonical binary MessagePack store and a NUON copy for Nushell-friendly reading
  $chunks | to msgpack | save -f data/nu_docs.msgpack
  $chunks | to nuon --indent 2 | save -f data/nu_docs_vectors.nuon

  # Build command_map: map command name (lowercase) -> { id, display }
  let pairs = (
    $chunks
    | where { |x| ($x.taxonomy.commands? | default []) != [] }
    | each { |chunk|
      let cmds_raw = (try { $chunk.taxonomy.commands } catch { [] })
      let cmds = ($cmds_raw | default [])
      if ($cmds != []) { $cmds | each { |cmd| { cmd: $cmd, id: $chunk.id } } } else { [] }
    }
    | flatten
  )

  # Build command_map via explicit loop to avoid reduce/version issues
  let command_map = {}
  for p in $pairs {
    let key = ($p.cmd | str downcase)
    let existing = (try { $command_map | get $key } catch { null })
    if ($existing == null) {
      let command_map = ($command_map | upsert ($key) { id: $p.id, display: $p.cmd })
    }
  }

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
