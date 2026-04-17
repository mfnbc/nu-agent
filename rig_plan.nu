export def rig-plan [
  manifest: string
  --lancedb-dir: string = "build/lancedb"
  --collection-prefix: string = ""
  --out: string = ""
] {
  if ((($manifest | default "") | str trim | str length) == 0) {
    error make { msg: "manifest path is required" }
  }

  if not ($manifest | path exists) {
    error make { msg: $"Manifest not found: ($manifest)" }
  }

  let data = (open --raw $manifest | from json)
  let files = ($data.files? | default [])

  if (($files | length) == 0) {
    error make { msg: "Manifest contains no file summaries" }
  }

  let entries = (
    $files
    | each { |item|
        let job = ($item.embedding_job? | default null)
        if $job == null {
          error make { msg: $"Missing embedding_job for file: ($item.file)" }
        }

        let job_path = ($job | path expand)
        let chunk_path = ($item.output? | default null)
        let source = ($item.source? | default null)
        let parsed = ($job_path | path parse)
        let stem = ($parsed.stem | default "embedding")

        {
          id: $stem
          embedding_job: $job_path
          chunk_file: $chunk_path
          source: $source
          lancedb_table: $"($collection_prefix)($stem)"
        }
      }
  )

  let plan = {
    manifest: ($manifest | path expand)
    lancedb_dir: ($lancedb_dir | path expand)
    jobs: $entries
  }

  if ((($out | default "") | str trim | str length) > 0) {
    let expanded = ($out | path expand)
    $plan | to json | save -f $expanded
  }

  $plan
}
