export def rig-run [
  plan: string
  --rig-bin: string = "rig"
  --model: string = "fastembed:BAAI/bge-small-en-v1.5"
  --batch-size: int = 512
  --execute
  --validate
  --embedding-column: string = "embedding"
  --score-column: string = "score"
] {
  if ((($plan | default "") | str trim | str length) == 0) {
    error make { msg: "plan path is required" }
  }

  if not ($plan | path exists) {
    error make { msg: $"Plan not found: ($plan)" }
  }

  let data = (open --raw $plan | from json)
  let lancedb_dir = ($data.lancedb_dir? | default null)

  if $lancedb_dir == null {
    error make { msg: "Plan missing lancedb_dir" }
  }

  let jobs = ($data.jobs? | default [])

  if (($jobs | length) == 0) {
    error make { msg: "Plan contains no jobs" }
  }

  let lancedb_path = ($lancedb_dir | path expand)
  mkdir $lancedb_path

  let job_list = (
    $jobs
    | each { |job|
        let job_path = ($job.embedding_job? | default null)
        if $job_path == null {
          error make { msg: "Plan job missing embedding_job" }
        }

        if not ($job_path | path exists) {
          error make { msg: $"Embedding job not found: ($job_path)" }
        }

        let table = ($job.lancedb_table? | default ($job.id? | default "rig_embeddings"))
        let chunk_file = ($job.chunk_file? | default null)
        let job_abs = ($job_path | path expand)
        let args = [
          "fastembed"
          "ingest"
          "--input"
          $job_abs
          "--lancedb"
          $lancedb_path
          "--table"
          $table
          "--batch-size"
          ($batch_size | into string)
          "--model"
          $model
        ]

        {
          id: ($job.id? | default $table)
          embedding_job: $job_abs
          chunk_file: $chunk_file
          lancedb_dir: $lancedb_path
          lancedb_table: $table
          command: {
            program: $rig_bin
            args: $args
          }
        }
      }
  )

  let results = if $execute {
    $job_list
    | each { |entry|
        let program = $entry.command.program
        let args = $entry.command.args
        let run = (do { ^$program ...$args } | complete)
        if $run.exit_code == 0 {
          $entry
          | upsert status "executed"
          | upsert exit_code $run.exit_code
          | upsert stderr ($run.stderr | default "")
          | upsert stdout ($run.stdout | default "")
        } else {
          $entry
          | upsert status "error"
          | upsert exit_code $run.exit_code
          | upsert stderr ($run.stderr | default "")
          | upsert stdout ($run.stdout | default "")
        }
      }
  } else {
    $job_list
    | each { |entry|
        $entry
        | upsert status "dry-run"
        | upsert exit_code null
        | upsert stderr ""
        | upsert stdout ""
      }
  }

  let validated = if $validate {
    $results
    | each { |entry|
        let status = ($entry.status? | default "dry-run")
        if $status == "executed" {
          let table_dir = ($entry.lancedb_dir? | default $lancedb_path)
          let dataset = ($table_dir | path join $"($entry.lancedb_table).lance")
          if not ($dataset | path exists) {
            $entry
            | upsert status "validation-error"
            | upsert validation {
                status: "missing-dataset"
                dataset: $dataset
              }
          } else {
            let data_files = (try { glob $"($dataset)/data/**/*.arrow" } catch { [] })
            let manifest_files = (try { glob $"($dataset)/**/*.manifest" } catch { [] })
            $entry
            | upsert validation {
                status: "ok"
                dataset: $dataset
                data_files: ($data_files | length)
                manifest_files: ($manifest_files | length)
              }
          }
        } else {
          $entry
          | upsert validation {
              status: "skipped"
              reason: "not-executed"
            }
        }
      }
  } else {
    $results
  }

  $validated
}
