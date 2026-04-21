#!/usr/bin/env nu
# Convenience wrapper: build the Rust helpers (if needed) and run the ingestion pipeline.

export def main [
  --input: string = "https://github.com/nushell/nushell.github.io.git"
  --out-dir: string = "build/rag/nu-docs"
  --attach-code-blocks
  --force
] {
  let embed_runner_path = [
    "./target/debug/embed_runner"
    "./crates/nu_plugin_rag/target/debug/embed_runner"
  ]
  let embed_runner_present = (
    ($embed_runner_path
      | where { |p| ($p | path exists) }
      | length) > 0
  )

  if not $embed_runner_present {
    print "Building nu_plugin_rag helpers (cargo build)..."
    ^cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml | ignore
  }

  let source_path = if ($input | str starts-with "http://") or ($input | str starts-with "https://") {
    let checkout = (($out_dir | path join "sources") | path join "nu-docs")
    if not ($checkout | path exists) {
      print $"Cloning ($input) -> ($checkout)"
      let parent = ($checkout | path parse | get parent | default "")
      if ($parent | str length) > 0 { mkdir $parent }
      ^git clone $input $checkout | ignore
    }
    $checkout
  } else {
    $input
  }

  print "Running ingestion pipeline..."
  let base_args = [
    "scripts/ingest-docs.nu"
    "--path" $source_path
    "--out-dir" $out_dir
  ]
  let args1 = if $force { ($base_args | append "--force") } else { $base_args }
  let args_final = if $attach_code_blocks { ($args1 | append "--attach-code-blocks") } else { $args1 }
  ^nu ...$args_final
}