#!/usr/bin/env nu

# Smoke test: run shredder with tokenizer mode and then run embed-and-stream.nu in dry-run

let out_dir = "build/smoke"
try { rm -r $out_dir } catch {}
mkdir $out_dir

let input = (try { $nu.args | get 0 } catch { "README.md" })

if not ($input | path exists) { error make { msg: ("input file not found: " + $input) } }

let shredded = ($out_dir | path join "shredded.msgpack")

# run the rust shredder in tokenizer mode (defaults to Mixedbread if env var set)
let shred_bin = "./target/debug/shredder"
if not ($shred_bin | path exists) { error make { msg: "shredder binary not found; build crates/nu_plugin_rag first" } }

let tokenizer = (try { $env.SHREDDER_TOKENIZER } catch { "mixedbread-ai/mxbai-embed-large-v1" })

print ("running shredder with tokenizer: " + $tokenizer)
# Run shredder and capture stdout to file (shredder writes msgpack to stdout)
let cmd = ($shred_bin + " '" + $input + "' --tokenizer '" + $tokenizer + "' --max-tokens 512 --overlap-tokens 64")
let proc = (do { $cmd } | capture)
if $proc.exit_code != 0 {
  error make { msg: ("shredder execution failed: " + ($proc.stderr | str trim)) }
}
$proc.stdout | save -f $shredded

if not ($shredded | path exists) { error make { msg: "shredded output not produced" } }

# Run embed-and-stream.nu in dry-run so we don't call external provider
let embed_script = "./scripts/embed-and-stream.nu"
if not ($embed_script | path exists) { error make { msg: "embed-and-stream.nu not found" } }

let embeddings_out = ($out_dir | path join "embeddings.msgpack")

print "running embed-and-stream.nu in dry-run"
let cmd2 = ("EMBEDDING_DRY_RUN=1 nu '" + $embed_script + "' '" + $shredded + "' '" + $embeddings_out + "'")
let proc2 = (do { $cmd2 } | capture)
if $proc2.exit_code != 0 {
  error make { msg: ("embed-and-stream execution failed: " + ($proc2.stderr | str trim)) }
}

if not ($embeddings_out | path exists) { error make { msg: "embeddings output not produced" } }

print "smoke test complete: shredded=($shredded) embeddings=($embeddings_out)"
