#!/usr/bin/env nu

# Simple integration test that runs the ingestion pipeline and validates embed_runner output
use ../tools.nu *

export def main [] {
  let out_dir = "build/test-pipeline"

  if ($out_dir | path exists) {
    rm -r $out_dir
  }

  # Run the nu-ingest script if available
  let _ = try { ./nu-ingest README.md --out-dir $out_dir } catch { null }

  # Expect embedding input in NUON
  let embedding_nuon = ($out_dir | path join "README.embedding_input.nuon")
  if not ($embedding_nuon | path exists) {
    error make { msg: "Expected embedding_input.nuon to be written by nu-ingest" }
  }

  # Run embed_runner to produce MessagePack embeddings
  let embed_bin = "./crates/nu_plugin_rag/target/debug/embed_runner"
  if not ($embed_bin | path exists) {
    error make { msg: "embed_runner binary not found; build crates/nu_plugin_rag first" }
  }

  let embeddings_out = ($out_dir | path join "README.embeddings.msgpack")

  # Produce document embeddings (full records) as before
  let _ = (run { nu --no-config-file -c $"$embed_bin --input $embedding_nuon --output $embeddings_out" })

  if not ($embeddings_out | path exists) {
    error make { msg: "Expected embeddings.msgpack to be written by embed_runner" }
  }

  # Use Nushell's native msgpack support to inspect the produced embeddings
  let records = (open $embeddings_out | from msgpack)

  if (($records | length) == 0) {
    error make { msg: "No embeddings found in embeddings.msgpack" }
  }

  # Validate first record shape
  let first = ($records | first)
  if not (($first | get id) != null) {
    error make { msg: "Embedding records missing id field" }
  }

  if not (($first | get embedding) != null) {
    error make { msg: "Embedding records missing embedding vector" }
  }

  print "Embeddings MessagePack produced and validated. Records: ($records | length)"

  # Now produce a query vector using embed_runner --vector-out and run nu-search
  let query_tmp = (mktemp --suffix .msgpack)
  let query_path = ($query_tmp | get path)

  # Create a small NUON query payload
  let q = { embedding_input: "test query" } | to nuon

  let _ = echo $q | do { ^$embed_bin --input - --vector-out $query_path }

  if not ($query_path | path exists) {
    error make { msg: "Expected query vector file to be written by embed_runner --vector-out" }
  }

  # Run nu-search against the produced doc embeddings
  let search_bin = "./crates/nu_plugin_rag/target/debug/nu-search"
  if not ($search_bin | path exists) {
    error make { msg: "nu-search binary not found; build crates/nu_plugin_rag first" }
  }

  let hits = (run { nu --no-config-file -c $"$search_bin --input $embeddings_out --query-vec $query_path --top-k 1 --out-format nuon" })

  # Parse the output and ensure we got at least one hit
  let parsed = ($hits | from nuon)
  if (($parsed | length) == 0) {
    error make { msg: "nu-search returned no hits" }
  }

  print "nu-search returned ($parsed | length) hits"
}
