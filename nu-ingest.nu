const DEFAULT_OUT_DIR = "build/nu-ingest"

export def ingest [
  path: string
  --out-dir: string = $DEFAULT_OUT_DIR
  --source: string = ""
  --attach-code-blocks
] {
  let input = ($path | path expand)

  if not ($input | path exists) {
    error make { msg: $"Input path not found: ($path)" }
  }

  mkdir $out_dir

  let files = if ($input | path type) == "dir" {
    glob ($input | path join "**/*.md") | sort
  } else {
    [$input]
  }

  if (($files | length) == 0) {
    error make { msg: $"No markdown files found under: ($path)" }
  }

  let summaries = ($files | each { |file|
    ingest-file $file $out_dir $source $attach_code_blocks
  })

  let manifest = {
    input: $input
    out_dir: ($out_dir | path expand)
    file_count: ($summaries | length)
    chunk_count: ($summaries | get chunk_count | math sum)
    embedding_jobs: ($summaries | get embedding_job)
    files: $summaries
  }

  let manifest_path = ($out_dir | path join "manifest.json")
  $manifest | to json | save -f $manifest_path

  $summaries
}


def ingest-file [file: string, out_dir: string, source_override: string, attach_code_blocks: bool] {
  let source = if ($source_override | str length) > 0 {
    $source_override
  } else {
    source-from-path $file
  }

  let raw = (if $attach_code_blocks {
    ^./nu-shredder $file --source $source --attach-code-blocks
  } else {
    ^./nu-shredder $file --source $source
  })

  let chunks = (
    $raw
    | lines
    | where { |line| ($line | str trim) != "" }
    | each { |line| $line | from json }
  )

  $chunks | each { |chunk| validate-chunk $chunk }

  let out_path = (chunk-output-path $file $out_dir)
  let embedding_path = (embedding-output-path $file $out_dir)
  let parent_dir = ($out_path | path parse | get parent)
  mkdir $parent_dir

  let nuon = (
    $chunks
    | each { |chunk| $chunk | to json -r }
    | str join (char nl)
  )

  $nuon | save -f $out_path

  let embedding_nuon = (
    $chunks
    | each { |chunk|
        {
          id: $chunk.id
          embedding_input: $chunk.embedding_input
        }
        | to json -r
      }
    | str join (char nl)
  )

  $embedding_nuon | save -f $embedding_path

  {
    file: $file
    source: $source
    output: $out_path
    embedding_job: $embedding_path
    chunk_count: ($chunks | length)
    status: "ok"
  }
}


def source-from-path [file: string] {
  let lower = ($file | str downcase)

  if ($lower | str contains "cookbook") {
    "nu_cookbook"
  } else if ($lower | str contains "book") or ($lower | str contains "commands") {
    "nu_book"
  } else {
    "nu_help"
  }
}


def chunk-output-path [file: string, out_dir: string] {
  output-path $file $out_dir "chunks"
}


def embedding-output-path [file: string, out_dir: string] {
  output-path $file $out_dir "embedding_input"
}


def output-path [file: string, out_dir: string, suffix: string] {
  let cwd = (pwd)
  let normalized = if ($file | str starts-with $cwd) {
    $file | str replace $cwd ""
  } else {
    $file
  }

  let rel = ($normalized | str replace --regex '^/+' "")
  let parsed = ($rel | path parse)
  let parent = ($parsed.parent | default "")
  let stem = ($parsed.stem | default "document")

  let filename = $"($stem).($suffix).nuon"

  if ($parent | str length) > 0 {
    $out_dir | path join $parent | path join $filename
  } else {
    $out_dir | path join $filename
  }
}


def validate-chunk [chunk: record] {
  let required = ["id" "identity" "hierarchy" "taxonomy" "data" "embedding_input"]
  let cols = ($chunk | columns)
  let missing = ($required | where { |key| $key not-in $cols })

  if (($missing | length) > 0) {
    error make { msg: $"Invalid chunk missing keys: (($missing | str join ', '))" }
  }

  if not (($chunk.identity | describe) | str starts-with "record") {
    error make { msg: "Invalid chunk identity field; expected a record" }
  }

  if not (($chunk.hierarchy | describe) | str starts-with "record") {
    error make { msg: "Invalid chunk hierarchy field; expected a record" }
  }

  if not (($chunk.taxonomy | describe) | str starts-with "record") {
    error make { msg: "Invalid chunk taxonomy field; expected a record" }
  }

  if not (($chunk.data | describe) | str starts-with "record") {
    error make { msg: "Invalid chunk data field; expected a record" }
  }

  $chunk
}
