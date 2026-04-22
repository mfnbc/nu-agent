#!/usr/bin/env nu

# 1. Capture environment variables safely
let remote_url = ($env.EMBEDDING_REMOTE_URL? | default "http://172.19.224.1:1234/v1/embeddings")
let model_name = ($env.EMBEDDING_MODEL? | default "text-embedding-mxbai-embed-large-v1")
let batch_size = ($env.EMBEDDING_BATCH_SIZE? | default 8 | into int)
let max_chars = ($env.EMBEDDING_MAX_CHARS? | default 1800 | into int)
let overlap = ($env.EMBEDDING_OVERLAP_CHARS? | default 200 | into int)

# 2. Define the chunking logic
def chunk_text [text: string, size: int, overlap: int] {
    let len = ($text | str length)
    if $len <= $size { return [($text + "\n.")] }

    let step = ($size - $overlap)
    let out = []
    let start = 0
    while ($start < $len) {
        let end = ($start + $size)
        # str substring expects a range; end is inclusive so use ($start..$end)
        let seg = ($text | str substring ($start..$end))
        let out = ($out | append ($seg + "\n."))
        let start = ($start + $step)
    }
    $out
}

# 3. Main processing pipeline
def main [] {
    # Prefer a positional arg when the script is run as: `nu scripts/embed-stream.nu <path>`.
    # Fall back to EMBED_INPUT_PATH env var, otherwise read stdin into a temp file.
    let arg_path = (try { $nu.args | get 0 } catch { null })
    let tmp = if ($arg_path != null) { $arg_path } else { ($env.EMBED_INPUT_PATH? | default "/tmp/nu_embed_stream_in.msgpack") }

    if ($arg_path == null) {
        if ($env.EMBED_INPUT_PATH? | default "") == "" {
            # No path provided: read stdin into a temp file
            open --raw - | save -f $tmp
        }
    }

    # Parse the provided file as MessagePack (top-level array). When the
    # script is invoked with a file argument (nu scripts/embed-stream.nu <path>),
    # open <path> | from msgpack works reliably and avoids pipeline try/catch issues.
    # Some Nushell configurations/open behaviors return structured values when
    # opening a .msgpack file, while others return binary that needs `from msgpack`.
    # Try both: if `from msgpack` fails, fall back to the opened value directly.
    # If the input file looks like msgpack, parse it as a stream of objects
    # (concatenated MessagePack) and collect into a list. Otherwise try json,
    # otherwise fall back to open's result.
    # Respect EMBEDDING_DRY_LIMIT at parse time to avoid parsing the entire
    # corpus when we're only doing a smoke test. Parse msgpack as a stream of
    # objects and collect only the requested number of records when the
    # environment variable is set.
    let dry_limit_raw = ($env.EMBEDDING_DRY_LIMIT? | default "")
    let recs_final = if ($dry_limit_raw != "") {
        let n = ($dry_limit_raw | into int)
        (try { open $tmp | from msgpack --objects | first $n | collect } catch { try { open $tmp | from json | first $n } catch { open $tmp | first $n } })
    } else {
        (try { open $tmp | from msgpack --objects | collect } catch { try { open $tmp | from json } catch { open $tmp } })
    }

    let chunks = (
        $recs_final
        | each { |r|
            let row = try { { id: $r.id, text: $r.text } } catch { { id: ($r | get 0), text: ($r | get 1) } }
            # Some MessagePack inputs encode text as a list of strings (lines).
            # Normalize to a single string for chunking by joining with newlines
            # when necessary. Use nested try/catch to handle whichever shape
            # the input provides (list-of-strings, single string, or other).
            let text_norm = (try { ($row.text | str join "\n") } catch { try { ($row.text | into string) } catch { "" } })
            let segs = (chunk_text $text_norm $max_chars $overlap)
            $segs | enumerate | each { |seg| { id: $"($row.id)_($seg.index)", input: $seg.item, source_id: $row.id, chunk_index: $seg.index } }
        }
        | flatten
    )

    # Batch and Post
    let total_chunks = ($chunks | length)
    # Preparing to send batches (silent to avoid stdout noise)

    # Create sliding windows (batches) and process them in an explicit loop
    let windows = ($chunks | window $batch_size --stride $batch_size)
    let wlen = ($windows | length)
    let i = 0
    let results = []
    while ($i < $wlen) {
        let batch_items = ($windows | get $i)
        let body = { model: $model_name, input: ($batch_items.input) }

        let emb_list = if ($env.EMBEDDING_DRY_RUN? | default "") == "1" {
            let n = ($batch_items | length)
            # produce n vectors of 1024 floats: [0.0, 0.001, 0.002, ...]
            (0..($n - 1)) | each { |ii| (0..1023 | each { |j| ($j | into float) / 1000.0 }) }
        } else {
            let resp = try { http post --content-type application/json $remote_url $body } catch {
                error make { msg: "HTTP post failed" }
            }
            (try { $resp.embeddings } catch {
                try { $resp.data | each { |d| (try { $d.embedding } catch { $d }) } } catch { $resp }
            })
        }

        if ($emb_list | length) != ($batch_items | length) {
            # embedding count mismatch - continue anyway
        }

        let j = 0
        let blen = ($batch_items | length)
        while ($j < $blen) {
            let item = ($batch_items | get $j)
            let emb = (try { $emb_list | get $j } catch { null })
            let truncated = if ($emb != null) { try { $emb | first 256 } catch { $emb } } else { null }
            let rec = { id: $item.id, source_id: $item.source_id, chunk_index: $item.chunk_index, input: $item.input, embedding: $truncated }
            let results = ($results | append $rec)
            let j = ($j + 1)
        }

        let i = ($i + 1)
    }

    # Cleanup temp file
    try { rm $tmp } catch { }

    # Output final binary to stdout
    # Emit final list of records as canonical MessagePack
    $results | to msgpack
}

main
