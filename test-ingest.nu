#!/usr/bin/env nu

use ./tools.nu *
use ./rig_plan.nu *
use ./rig_run.nu *
use ./kuzu_plan.nu *
use ./kuzu_run.nu *

export def main [] {
  let out_dir = "build/test-smoke-ingest"

  if ($out_dir | path exists) {
    rm -r $out_dir
  }

  let _ = (./nu-ingest README.md --out-dir $out_dir)

  let result = {
    manifest: ($out_dir | path join "manifest.json")
    chunks: ($out_dir | path join "README.chunks.jsonl")
    embedding: ($out_dir | path join "README.embedding_input.jsonl")
  }

  if not ($result.manifest | path exists) {
    error make { msg: "Expected manifest.json to be written" }
  }

  if not ($result.chunks | path exists) {
    error make { msg: "Expected chunk JSONL to be written" }
  }

  if not ($result.embedding | path exists) {
    error make { msg: "Expected embedding input JSONL to be written" }
  }

  let embedding_first = (
    open --raw $result.embedding
    | lines
    | first
    | from json
  )

  let embedding_keys = ($embedding_first | columns)
  let embedding_missing = (["id" "embedding_input"] | where { |k| $k not-in $embedding_keys })

  if (($embedding_missing | length) > 0) {
    error make { msg: "Embedding input JSONL missing required keys" }
  }

  let plan_path = ($out_dir | path join "rig-plan.json")
  let plan = (rig-plan $result.manifest --lancedb-dir "build/test-smoke-lancedb" --collection-prefix "test_" --out $plan_path)

  if (($plan.jobs | length) == 0) {
    error make { msg: "Expected rig-plan to produce at least one job" }
  }

  let job0 = ($plan.jobs | first)
  let rig_inspect = (inspect-rig-plan --path $plan_path --limit 1)

  if ($rig_inspect.job_total <= 0) {
    error make { msg: "inspect-rig-plan should report jobs" }
  }

  if (($rig_inspect.jobs | length) == 0) {
    error make { msg: "inspect-rig-plan limit should return sample jobs" }
  }

  let embedding_hits = (search-embedding-input --path $out_dir --pattern "nu-agent" --limit 5)

  if ($embedding_hits.total <= 0) {
    error make { msg: "search-embedding-input should find matches" }
  }
  let required_job_keys = ["id" "embedding_job" "lancedb_table" "chunk_file"]
  let missing_job_keys = ($required_job_keys | where { |k| $k not-in ($job0 | columns) })

  if (($missing_job_keys | length) > 0) {
    error make { msg: "Rig plan entry missing required keys" }
  }

  let rig_run_results = (rig-run $plan_path)

  if (($rig_run_results | length) == 0) {
    error make { msg: "Expected rig-run to return at least one result" }
  }

  if (($rig_run_results | first | get status) != "dry-run") {
    error make { msg: "rig-run should default to dry-run" }
  }

  let rig_validated = (rig-run $plan_path --validate)
  let validation0 = ($rig_validated | first | get validation)

  if (($validation0.status? | default "") != "skipped") {
    error make { msg: "Validation should skip when not executed" }
  }

  let rig_execute_results = (rig-run $plan_path --execute --rig-bin "false" --validate)

  if (($rig_execute_results | first | get status) != "error") {
    error make { msg: "rig-run should report errors when execution fails" }
  }

  if (($rig_execute_results | first | get validation | get status) != "skipped") {
    error make { msg: "Validation should skip when execution fails" }
  }

  let kuzu_out_dir = ($out_dir | path join "kuzu-plan")
  let kuzu_plan_path = ($out_dir | path join "kuzu-plan.json")
  let kuzu_plan = (kuzu-plan $result.manifest --out-dir $kuzu_out_dir --out $kuzu_plan_path)

  if not ($kuzu_plan_path | path exists) {
    error make { msg: "Expected kuzu plan json to be written" }
  }

  if not ($kuzu_plan.nodes_csv | path exists) {
    error make { msg: "Expected kuzu nodes csv to be written" }
  }

  if ($kuzu_plan.node_count <= 0) {
    error make { msg: "Expected kuzu nodes csv to contain rows" }
  }

  if not ($kuzu_plan.edges_csv | path exists) {
    error make { msg: "Expected kuzu edges csv to be written" }
  }

  let kuzu_dry = (kuzu-run $kuzu_plan_path --db ($out_dir | path join "kuzu/db") --validate)
  let kuzu_val = ($kuzu_dry | first | get validation)

  if (($kuzu_val.status? | default "") != "csv-count") {
    error make { msg: "Dry-run validation should report csv-count" }
  }

  if ($kuzu_val.node_rows != $kuzu_plan.node_count) {
    error make { msg: "Dry-run validation should report matching node counts" }
  }

  let kuzu_execute = (kuzu-run $kuzu_plan_path --db ($out_dir | path join "kuzu/db2") --execute --kuzu-bin "false" --validate)
  let kuzu_execute_validation = ($kuzu_execute | first | get validation)

  if (($kuzu_execute | first | get status) != "error") {
    error make { msg: "kuzu-run should report error when execution fails" }
  }

  if (($kuzu_execute_validation.status? | default "") != "skipped") {
    error make { msg: "Failed execution should skip validation" }
  }

  if (($kuzu_execute_validation.reason? | default "") != "execution-error") {
    error make { msg: "Failed execution should report execution-error reason" }
  }

  let kuzu_nodes_sample = (inspect-kuzu-plan --path $kuzu_plan_path --kind "nodes" --limit 2)

  if (($kuzu_nodes_sample.rows | length) == 0) {
    error make { msg: "inspect-kuzu-plan nodes sample should return rows" }
  }

  let hits = (search-chunks --path $out_dir --pattern "Enrichment Contract")

  if (($hits | length) == 0) {
    error make { msg: "Expected search-chunks to return evidence from ingested chunks" }
  }

  print "Passed ingestion smoke test."
}
