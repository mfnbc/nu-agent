#!/usr/bin/env nu

# Import Kùzu CSVs into a local Kùzu database (opt-in helper)

export def main [
  --plan: string
  --out-dir: string = "build/rag/kuzu"
  --execute-kuzu
] {
  if (($plan | default "" | str trim | str length) == 0) {
    error make { msg: "Missing --plan argument (kuzu-plan.json path)" }
  }

  if not ($plan | path exists) {
    error make { msg: $"Kùzu plan not found: ($plan)" }
  }

  let p = (open --raw $plan | from json)
  let nodes = ($p.nodes_csv? | default null)
  let edges = ($p.edges_csv? | default null)

  if $nodes == null or $edges == null {
    error make { msg: "Plan missing nodes_csv or edges_csv" }
  }

  if not ($nodes | path exists) {
    error make { msg: $"nodes_csv not found: ($nodes)" }
  }

  if not ($edges | path exists) {
    error make { msg: $"edges_csv not found: ($edges)" }
  }

  if not ($execute_kuzu) {
    {
      status: "ready",
      nodes_csv: $nodes,
      edges_csv: $edges,
      message: "CSV exports ready. Rerun with --execute-kuzu to import into a local Kùzu instance."
    }
  } else {
    if (which kuzu | length) == 0 {
      error make { msg: "kuzu binary not found in PATH" }
    }

    let db_dir = ($out_dir | path join "kuzu_db")
    mkdir $out_dir

    # Build import command. This is kept minimal and relies on kuzu CLI.
    let cmd = $"kuzu import --nodes-csv ($nodes) --edges-csv ($edges) --out ($db_dir)"

    let result = (do { ^$nu.current-exe -c $cmd } | complete)

    if $result.exit_code == 0 {
      {
        status: "imported",
        db_dir: $db_dir
      }
    } else {
      error make { msg: $result.stderr }
    }
  }
}
