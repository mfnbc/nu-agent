#!/usr/bin/env nu

# Simple replacement for the Rust nu_embedder: convert a msgpack stream of
# maps with {id, vector} or {id, embedding} into a JSON lines or NUON file.

let in_path = (try { $nu.args | get 0 } catch { "" })
let out_path = (try { $nu.args | get 1 } catch { "" })
if $in_path == "" || $out_path == "" { echo "Usage: nu_embedder.nu <in.msgpack> <out.json>"; exit 2 }

let items = try { open $in_path | from msgpack --objects | collect } catch { error make { msg: "failed to read msgpack input" } }

for item in $items {
    let id = (try { $item.id } catch { "" })
    let vec = (try { $item.vector } catch { try { $item.embedding } catch { [] } })
    let out = { id: $id, vector: $vec }
    $out | append $out
}

# write out as pretty JSON array
($out | to json --pretty) > $out_path
