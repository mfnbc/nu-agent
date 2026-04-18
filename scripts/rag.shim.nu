#!/usr/bin/env nu

# Lightweight shim that exposes rag.* Nushell commands by invoking the nu_plugin_rag binary

def rag.prepare-deps [--out-dir: string = ""] {
  let bin = (path join (pwd) "crates/nu_plugin_rag/target/debug/nu_plugin_rag")
  if not ($bin | path exists) {
    error make { msg: $"nu_plugin_rag binary not found at: ($bin). Build the crate first." }
  }

  let out = (do { ^$bin prepare-deps --out-dir $out_dir } | lines | str join "\n")
  echo $out
}

def rag.build [--input: string, --out-dir: string = "build/rag/nu-docs", --attach-code-blocks, --force] {
  let bin = (path join (pwd) "crates/nu_plugin_rag/target/debug/nu_plugin_rag")
  if not ($bin | path exists) {
    error make { msg: $"nu_plugin_rag binary not found at: ($bin). Build the crate first." }
  }

  let flags = (if $attach_code_blocks { "--attach-code-blocks" } else { "" })
  let force_flag = (if $force { "--force" } else { "" })

  let out = (do { ^$bin build --input $input --out-dir $out_dir $flags $force_flag } | lines | str join "\n")
  echo $out
}

def rag.status [--out-dir: string = "build/rag/nu-docs"] {
  let bin = (path join (pwd) "crates/nu_plugin_rag/target/debug/nu_plugin_rag")
  if not ($bin | path exists) {
    error make { msg: $"nu_plugin_rag binary not found at: ($bin). Build the crate first." }
  }

  let out = (do { ^$bin status --out-dir $out_dir } | lines | str join "\n")
  echo $out
}

export use commands *
