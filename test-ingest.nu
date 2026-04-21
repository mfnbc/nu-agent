#!/usr/bin/env nu

export def main [] {
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

  if ($embed_runner | str length) == 0 {
    ^cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml | ignore
  }

  let embed_runner = (
    $embed_runner_candidates
    | where { |p| ($p | path exists) }
    | get 0?
    | default ""
  )

  if ($embed_runner | str length) == 0 {
    error make { msg: "embed_runner binary missing after build" }
  }

  let out_dir = "build/test-rag"
  if ($out_dir | path exists) { rm -r $out_dir }

  ^nu scripts/ingest-docs.nu --path README.md --out-dir $out_dir --force

  if not ("data/nu_docs.msgpack" | path exists) {
    error make { msg: "Expected data/nu_docs.msgpack to exist" }
  }

  let embeddings_path = ($out_dir | path join "embeddings/corpus.embeddings.msgpack")
  if not ($embeddings_path | path exists) {
    error make { msg: "Expected embeddings to be generated" }
  }

  let embedding_count = (open --raw $embeddings_path | from msgpack | length)
  if $embedding_count == 0 {
    error make { msg: "Embeddings file is empty" }
  }

  let search_binary = (
    ["./target/debug/nu-search", "./crates/nu_plugin_rag/target/debug/nu-search", "./target/release/nu-search", "./crates/nu_plugin_rag/target/release/nu-search"]
    | where { |p| ($p | path exists) }
    | get 0?
    | default null
  )

  if $search_binary != null {
    let query_spec = "build/test-rag/query.embed.nuon"
    [[embedding_input]; ["how to list files"]] | to json | save -f $query_spec
    let query_vec = ($out_dir | path join "query.msgpack")
    ^$embed_runner --input $query_spec --vector-out $query_vec | ignore

    let results = (^$search_binary --input $embeddings_path --query-vec $query_vec --top-k 1 --out-format json | from json)
    if (($results | length) == 0) {
      error make { msg: "nu-search returned no results" }
    }
  }

  print "Ingestion smoke test passed."
}
