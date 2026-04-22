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
    if ($adaptive == "0") { print -e $"embed-and-stream: adaptive disabled, using batch_size=($batch_size)"; return $batch_size }
    # Build probe payload with repeated first text if necessary.
    # Support multiple input shapes: msgpack stream, ndjson (one JSON object per line),
    # or a single JSON array/object.
    let docs = try { open --raw $in_path | from msgpack --objects | rename -c {embedding_input: input} } catch {
        try { open $in_path | lines | each { |l| (try { $l | from json } catch { $l }) } } catch { open $in_path }
    }

    let sample = try { $docs | first 1 | get 0 | get input } catch { try { $docs | get 0 | get input } catch { "health-check" } }
    let inputs = (0..($probe_size - 1) | each { $sample })
    let body = { model: $model_name, input: $inputs }
    if ($dry_run == "1") { print -e "embed-and-stream: dry-run probe, returning 1"; return 1 }
    let resp = try { http post --content-type application/json $remote_url $body } catch { print -e "embed-and-stream: probe request failed"; null }
    if ($resp == null) { print -e "embed-and-stream: probe failed, falling back to stream (1)"; return 1 }
    let emb = try { $resp.embeddings } catch {
        try { $resp.data | each { |d| (try { $d.embedding } catch { $d }) } } catch { $resp }
    }
    if ($emb | length) == 0 {
        print -e "embed-and-stream: probe returned empty embeddings, falling back to stream"
        return 1
        } else {
        print -e $"embed-and-stream: probe succeeded, using batch_size=($batch_size)"
        $batch_size
        }
    }

def stream_embeddings [in_path: string, out_path: string] {
    # probe to decide batch size
    let effective_batch = probe_provider $in_path
    print -e $"embed-and-stream: effective_batch = ($effective_batch)"

    # read input as stream of records (support .nuon and .msgpack)
    # Read items as a list of records regardless of input encoding
    let items = try { open --raw $in_path | from msgpack --objects | rename -c {embedding_input: input} | collect } catch {
        try { open $in_path | lines | each { |l| (try { $l | from json } catch { $l }) } | collect } catch { open $in_path | collect }
    }

    # incremental dedupe: skip items whose id already exists in out_path
    let skip_existing = ($env.EMBEDDING_SKIP_EXISTING? | default "1")
    let existing_ids = if ($skip_existing == "1") {
        try { open --raw $out_path | from msgpack --objects | get id | collect } catch { [] }
    } else { [] }

    let total_before = ($items | length)
    # compute filtered items into a new variable to avoid Nushell shadowing pitfalls
    let filtered_items = if ($existing_ids | length) > 0 {
        ($items | where { not ($existing_ids | any? { |eid| $eid == $it.id }) } | collect)
    } else {
        $items
    }

    let skipped = ($total_before - ($filtered_items | length))
    print -e $"embed-and-stream: skipped already-embedded = ($skipped); new = ($filtered_items | length)"
    if ($filtered_items | length) == 0 { print -e "embed-and-stream: nothing to do, exiting"; return }

    # prepare output file (only remove if user explicitly disables skipping)
    if ($skip_existing == "0") { try { rm $out_path } catch {} }

    # ensure batch size isn't larger than the number of items (window may emit no windows)
    let total_items = ($filtered_items | length)
    let adjusted_batch = if ($effective_batch > $total_items) { $total_items } else { $effective_batch }
    print -e $"embed-and-stream: adjusted_batch = ($adjusted_batch)"

    # Build results by mapping over windows and flattening (avoids list concat/append differences)
    let results = ($filtered_items | window $adjusted_batch --stride $adjusted_batch | each { |batch|
        let texts = ($batch.input)
        let body = { model: $model_name, input: $texts }
        let emb_list = if ($dry_run == "1") {
            print -e "embed-and-stream: dry-run enabled, skipping HTTP call for a batch"
            ($texts | each { [0] })
        } else {
            let resp = try { http post --content-type application/json $remote_url $body } catch { error make { msg: "embedding request failed" } }
            try { $resp.embeddings } catch {
                try { $resp.data | each { |d| (try { $d.embedding } catch { $d }) } } catch { $resp }
            }
        }

        # debug prints
        print -e $"embed-and-stream: received emb_list length = (($emb_list | length))"
        if (($emb_list | length) > 0) { print -e $"embed-and-stream: first emb length = ((($emb_list | first) | length))" }

        # produce records for this batch
        (0..(($emb_list | length) - 1) | each { |i| let emb = $emb_list | get $i; let item = $batch | get $i; { id: $item.id, text: $item.input, embedding: ($emb | first 1024), metadata: { source: "embed-and-stream" } } })
    } | flatten)

    # flush results to disk as concatenated MessagePack maps
    if ($results | length) == 0 { print -e "embed-and-stream: no results to write"; return }
    $results | each { |r| ($r | to msgpack) | save --append $out_path }
}

def main [in_path: string, out_path: string = "out.msgpack"] {
    # Nushell will map positional args to these parameters when the script is run
    if ($in_path | is-empty) {
        error make { msg: "Usage: embed-and-stream.nu <input> <output>" }
    }

    # print to stderr using print with -e flag to send to stderr in this nushell version
    print -e "embed-and-stream: Processing ($in_path) -> ($out_path)"
    stream_embeddings $in_path $out_path
}
