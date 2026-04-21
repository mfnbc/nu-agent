#!/usr/bin/env nu
# Normalise shredder output into the files consumed by nu-agent tools and the embedding runner.

export def main [] {
  if not ("build/nu_ingest" | path exists) {
    error make { msg: "build/nu_ingest not found; run nu-shredder on your corpus first" }
  }

  mkdir data

  # If a consolidated chunks corpus is not present, try to aggregate per-file
  # .chunks.msgpack files produced by the shredder. This removes a manual
  # aggregation step and makes the pipeline simpler to run.
  if not ("build/nu_ingest/chunks.msgpack" | path exists) and not ("build/nu_ingest/chunks.nuon" | path exists) {
    let per_files = (try { ls build/nu_ingest | where name =~ '\\.chunks.msgpack$' | get name } catch { [] })
    if (($per_files | length) > 0) {
      print $"Found ($per_files | length) per-file .chunks.msgpack - aggregating into build/nu_ingest/chunks.msgpack"
      let all = []
      for f in $per_files {
        # open each file and decode MessagePack
        let recs = try { open ($"build/nu_ingest/$f") | from msgpack } catch { [] }
        if ($recs != []) { let all = ($all + $recs) }
      }

      # Persist aggregated corpus
      $all | to msgpack | save -f build/nu_ingest/chunks.msgpack
      $all | to nuon --indent 2 | save -f build/nu_ingest/chunks.nuon
      let n = ($all | length)
      print $"Aggregated ($n) chunks into build/nu_ingest/chunks.msgpack"
    }
  }

  # Load aggregated chunks from MessagePack (preferred) or NUON
  let chunks = if ("build/nu_ingest/chunks.msgpack" | path exists) {
    open --raw build/nu_ingest/chunks.msgpack | from msgpack
  } else if ("build/nu_ingest/chunks.nuon" | path exists) {
    open build/nu_ingest/chunks.nuon | from nuon
  } else {
    error make { msg: "No chunk corpus found (expected build/nu_ingest/chunks.msgpack)" }
  }

  # Persist canonical chunk stores
  $chunks | to msgpack | save -f data/nu_docs.msgpack
  $chunks | to nuon --indent 2 | save -f data/nu_docs_vectors.nuon

  # Build command map (lowercase command -> { id, display })
  let command_pairs = (
    $chunks
    | where { |c| ($c.taxonomy.commands? | default []) != [] }
    | each { |c|
        $c.taxonomy.commands
        | default []
        | each { |cmd| { key: ($cmd | str downcase), value: { id: $c.id, display: $cmd } } }
      }
    | flatten
  )

  let command_map = (
    $command_pairs
    | reduce --fold {} { |pair, acc|
        let existing = (try { $acc | get $pair.key } catch { null })
        if $existing != null {
          $acc
        } else {
          $acc | upsert $pair.key $pair.value
        }
      }
  )

  $command_map | to nuon --indent 2 | save -f data/command_map.nuon
  $command_map | to msgpack | save -f data/command_map.msgpack

  # Prepare embedding input tables
  let embedding_input = (
    $chunks
    | where { |c| ($c.embedding_input? | default "") != "" }
    | each { |c| { id: $c.id, text: $c.embedding_input } }
  )

  $embedding_input | to nuon --indent 2 | save -f build/nu_ingest/embedding_input.nuon
  $embedding_input | to msgpack | save -f build/nu_ingest/embedding_input.msgpack
  $embedding_input | to json --indent 2 | save -f build/nu_ingest/embedding_input.json
  $embedding_input | to json --indent 2 | save -f build/nu_ingest/embedding_input.embed.nuon

  let chunk_count = ($chunks | length)
  let command_count = ($command_map | columns | length)
  let embedding_count = ($embedding_input | length)

  print $"Chunks: ($chunk_count) -> data/nu_docs.msgpack"
  print $"Commands: ($command_count) -> data/command_map.nuon"
  print $"Embedding rows: ($embedding_count) -> build/nu_ingest/embedding_input.json"
}
