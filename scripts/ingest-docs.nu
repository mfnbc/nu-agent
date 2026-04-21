#!/usr/bin/env nu
# High-level ingestion helper: shred Markdown, build command maps, and generate embeddings.

def should-keep-file [path: string, allow_non_english: bool] {
  if $allow_non_english {
    true
  } else {
    let segments = ($path | path split)
    let has_foreign_locale = (
      $segments
      | any { |seg|
          let lower = ($seg | str downcase)
          let looks_like_locale = ($lower =~ '^[a-z]{2}(-[a-z0-9]+)?$')
          ($looks_like_locale) and (not ($lower | str starts-with "en"))
        }
    )
    not $has_foreign_locale
  }
}

export def main [
  --path: string = "docs/"
  --out-dir: string = "build/rag/run"
  --source: string = ""
  --attach-code-blocks
  --force
  --allow-non-english
] {
  let input_path = ($path | path expand)

  if not ($input_path | path exists) {
    error make { msg: $"Input path not found: ($path)" }
  }

  if $force {
    if ("build/nu_ingest" | path exists) { rm -r build/nu_ingest }
    if ("data" | path exists) { rm -r data }
  }

  if not ("build/nu_ingest" | path exists) { mkdir build/nu_ingest }
  if not ($out_dir | path exists) { mkdir $out_dir }

  let files = if (($input_path | path type) == "dir") {
    glob ($input_path | path join "**/*.md")
      | each { |f| $f | path expand }
      | where { |f| ($f | path type) == "file" }
      | where { |f| should-keep-file $f $allow_non_english }
  } else {
    [$input_path]
    | where { |f| should-keep-file $f $allow_non_english }
  }

  if (($files | length) == 0) {
    error make { msg: $"No markdown files found under: ($path)" }
  }

  let file_count = ($files | length)
  print $"Shredding ($file_count) markdown files..."

  for file in $files {
    if ($source | str length) > 0 {
      if $attach_code_blocks {
        ./nu-shredder $file --source $source --attach-code-blocks
      } else {
        ./nu-shredder $file --source $source
      }
    } else {
      if $attach_code_blocks {
        ./nu-shredder $file --attach-code-blocks
      } else {
        ./nu-shredder $file
      }
    }
  }

  print "Normalising chunk outputs..."
  nu scripts/make-data-from-chunks.nu

  # Prepare output layout
  let chunks_dir = ($out_dir | path join "chunks")
  let embedding_dir = ($out_dir | path join "embedding_input")
  let data_dir = ($out_dir | path join "data")
  if not ($chunks_dir | path exists) { mkdir $chunks_dir }
  if not ($embedding_dir | path exists) { mkdir $embedding_dir }
  if not ($data_dir | path exists) { mkdir $data_dir }

  cp --force data/nu_docs.msgpack ($data_dir | path join "nu_docs.msgpack")
  cp --force data/nu_docs_vectors.nuon ($data_dir | path join "nu_docs_vectors.nuon")
  cp --force data/command_map.nuon ($data_dir | path join "command_map.nuon")
  if ("data/command_map.msgpack" | path exists) {
    cp --force data/command_map.msgpack ($data_dir | path join "command_map.msgpack")
  }

  cp --force build/nu_ingest/chunks.msgpack ($chunks_dir | path join "corpus.chunks.msgpack")
  if ("build/nu_ingest/chunks.nuon" | path exists) {
    cp --force build/nu_ingest/chunks.nuon ($chunks_dir | path join "corpus.chunks.nuon")
  }

  cp --force build/nu_ingest/embedding_input.nuon ($embedding_dir | path join "corpus.embedding_input.nuon")
  cp --force build/nu_ingest/embedding_input.msgpack ($embedding_dir | path join "corpus.embedding_input.msgpack")
  if ("build/nu_ingest/embedding_input.embed.nuon" | path exists) {
    cp --force build/nu_ingest/embedding_input.embed.nuon ($embedding_dir | path join "corpus.embedding_input.embed.nuon")
  }

  let embed_runner_candidates = [
    "./target/debug/embed_runner"
    "./crates/nu_plugin_rag/target/debug/embed_runner"
    "./target/release/embed_runner"
    "./crates/nu_plugin_rag/target/release/embed_runner"
  ]

  let embed_runner = (
    $embed_runner_candidates
    | where { |p| ($p | path exists) }
    | get 0?
    | default ""
  )

  if ($embed_runner | str length) > 0 {
    let embeddings_dir = ($out_dir | path join "embeddings")
    if not ($embeddings_dir | path exists) { mkdir $embeddings_dir }
    let embed_input = "build/nu_ingest/embedding_input.embed.nuon"
    let embed_output = ($embeddings_dir | path join "corpus.embeddings.msgpack")

    print $"Running embed_runner -> ($embed_output)"
    ^$embed_runner --input $embed_input --output $embed_output | ignore
  } else {
    print "embed_runner binary not found; skip embedding generation (run cargo build first)"
  }

  print $"Ingestion complete. Outputs duplicated under: ($out_dir)"
}