#!/usr/bin/env nu

# Replacement for the Rust embed_runner: stream inputs to the remote embedding
# provider and write concatenated MessagePack maps as a streaming output.

let remote_url = ($env.EMBEDDING_REMOTE_URL? | default "http://172.19.224.1:1234/v1/embeddings")
let model_name = ($env.EMBEDDING_MODEL? | default "text-embedding-mxbai-embed-large-v1")
let batch_size = ($env.EMBEDDING_BATCH_SIZE? | default 256 | into int)
let probe_size = ($env.EMBEDDING_PROBE_SIZE? | default 1024 | into int)
let adaptive = ($env.EMBEDDING_ADAPTIVE_BATCHING? | default "1")
let dry_run = ($env.EMBEDDING_DRY_RUN? | default "0")

def normalize_input [val] {
    # Accept either {id, text} style or positional maps
    let id = (try { $val.id } catch { try { $val | get 0 } catch { "" } })
    let text = (try { $val.embedding_input } catch { try { $val.text } catch { try { $val.data } catch { "" } } })
    { id: $id, text: $text }
}

def probe_provider [in_path:string] {
    if ($adaptive == "0") { eprintln "embed-and-stream: adaptive disabled, using batch_size=$batch_size"; return $batch_size }
    # Build probe payload with repeated first text if necessary
    let sample = (open $in_path | from msgpack --objects | first 1 | get 0 | get embedding_input)
    let sample = if ($sample == null) { "health-check" } else { $sample }
    let inputs = (0..($probe_size - 1) | each { $sample })
    let body = { model: $model_name, input: $inputs }
    if ($dry_run == "1") { eprintln "embed-and-stream: dry-run probe, returning 1"; return 1 }
    let resp = try { http post --content-type application/json $remote_url $body } catch { eprintln "embed-and-stream: probe request failed"; null }
    if ($resp == null) { eprintln "embed-and-stream: probe failed, falling back to stream (1)"; return 1 }
    let emb = try { $resp.embeddings } catch {
        try { $resp.data | each { |d| (try { $d.embedding } catch { $d }) } } catch { $resp }
    }
    if ($emb | length) == 0 {
        eprintln "embed-and-stream: probe returned empty embeddings, falling back to stream"
        return 1
    } else {
        eprintln "embed-and-stream: probe succeeded, using batch_size=$batch_size"
        $batch_size
    }
}

def stream_embeddings [in_path: string, out_path: string] {
    # probe to decide batch size
    let effective_batch = probe_provider $in_path
    eprintln "embed-and-stream: effective_batch = ($effective_batch)"

    # read input as stream of records (support .nuon and .msgpack)
    let items = try { open $in_path | from msgpack --objects | collect } catch { try { open $in_path | from json | collect } catch { open $in_path | collect } }

    # prepare output file
    try { rm $out_path } catch {}

    let idx = 0
    for batch in ($items | window $effective_batch --stride $effective_batch) {
        let texts = ($batch.input)
        let body = { model: $model_name, input: $texts }
        let emb_list = if ($dry_run == "1") {
            eprintln "embed-and-stream: dry-run enabled, skipping HTTP call for batch starting at index ($idx)"
            # produce a fake embedding of zeros matching expected shape
            ($texts | each { [0] })
        } else {
            let resp = try { http post --content-type application/json $remote_url $body } catch { error make { msg: "embedding request failed" } }
            try { $resp.embeddings } catch {
                try { $resp.data | each { |d| (try { $d.embedding } catch { $d }) } } catch { $resp }
            }
        }
        let j = 0
        for emb in $emb_list {
            let item = ($batch | get $j)
            let rec = { id: $item.id, text: $item.input, embedding: ($emb | first 1024), metadata: { source: "embed-and-stream" } }
            # append single record as MessagePack map (use save --append for compatibility)
            $rec | to msgpack | save --append $out_path
            let j = ($j + 1)
        }
        let idx = ($idx + ($batch | length))
    }
}

def main [] {
    let in_path = (try { $nu.args | get 0 } catch { "" })
    let out_path = (try { $nu.args | get 1 } catch { "out.msgpack" })
    if $in_path == "" { error make { msg: "Usage: embed-and-stream.nu <input> <output>" } }
    stream_embeddings $in_path $out_path
}

main
