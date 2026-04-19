# Convert a JSONL file to NUON
# Usage: nu scripts/jsonl-to-nuon.nu --input data/nu_docs_vectors.jsonl --output data/nu_docs_vectors.nuon

export def main [--input: string = "data/nu_docs_vectors.jsonl", --output: string = "data/nu_docs_vectors.nuon"] {
    if (not ($input | path exists)) { error make { msg: "input not found: ($input)" } }

    let rows = []
    let raw = (open --raw $input)
    let lines = ($raw | lines)
    for line in $lines {
        if (($line | str trim) == "") { continue }
        let obj = try { ($line | from json) } catch { null }
        if ($obj != null) { let rows = ($rows | append $obj) }
    }

    if ($rows | length) == 0 { error make { msg: "no rows parsed from ($input)" } }

    # Save as NUON
    $rows | to nuon --indent 2 | save -f $output
    print "Wrote NUON to ($output)"
}

main
