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
}
