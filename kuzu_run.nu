export def kuzu-run [
  plan: string
  --db: string = "build/kuzu/db"
  --kuzu-bin: string = "kuzu"
  --execute
  --validate
] {
  if ((($plan | default "") | str trim | str length) == 0) {
    error make { msg: "plan path is required" }
  }

  if not ($plan | path exists) {
    error make { msg: $"Plan not found: ($plan)" }
  }

  let data = (open --raw $plan | from json)
  let nodes = ($data.nodes_csv? | default null)
  let edges = ($data.edges_csv? | default null)
  let out_dir = ($data.out_dir? | default null)
  let expected_nodes = ($data.node_count? | default null)
  let expected_edges = ($data.edge_count? | default null)

  if $nodes == null {
    error make { msg: "Plan missing nodes_csv" }
  }

  if $edges == null {
    error make { msg: "Plan missing edges_csv" }
  }

  if not ($nodes | path exists) {
    error make { msg: $"Nodes CSV not found: ($nodes)" }
  }

  if not ($edges | path exists) {
    error make { msg: $"Edges CSV not found: ($edges)" }
  }

  if ((($db | default "") | str trim | str length) == 0) {
    error make { msg: "Database path (--db) is required" }
  }

  let db_path = ($db | path expand)
  mkdir ($db_path | path parse | get parent)

  let out_base = if $out_dir == null {
    ($plan | path parse | get parent | default (pwd))
  } else {
    $out_dir
  }

  mkdir $out_base

  let script_path = ($out_base | path join "kuzu-import.sql")

  let nodes_abs = ($nodes | path expand)
  let edges_abs = ($edges | path expand)

  let node_rows = (try { open $nodes_abs | length } catch { null })
  let edge_rows = (try { open $edges_abs | length } catch { null })

  let nodes_sql_path = ($nodes_abs | str replace "'" "''")
  let edges_sql_path = ($edges_abs | str replace "'" "''")

  let copy_nodes = (["COPY chunk_nodes FROM '" $nodes_sql_path "' (HEADER=true);"] | str join "")
  let copy_edges = (["COPY chunk_edges FROM '" $edges_sql_path "' (HEADER=true);"] | str join "")

  let sql_lines = [
    "CREATE TABLE IF NOT EXISTS chunk_nodes ("
    "  chunk_id STRING PRIMARY KEY,"
    "  source STRING,"
    "  path STRING,"
    "  checksum STRING,"
    "  title STRING,"
    "  heading_path STRING,"
    "  chunk_type STRING,"
    "  commands STRING,"
    "  parent_id STRING,"
    "  order_value INT64"
    ");"
    "CREATE TABLE IF NOT EXISTS chunk_edges ("
    "  parent_id STRING,"
    "  child_id STRING,"
    "  source STRING,"
    "  path STRING"
    ");"
    $copy_nodes
    $copy_edges
  ]

  let sql = ($sql_lines | str join (char nl))

  $sql | save -f $script_path

  let command = {
    program: $kuzu_bin
    args: [
      "--database"
      $db_path
      "--script"
      $script_path
    ]
    script: $script_path
  }

  let result = if $execute {
    let run = (do { ^$command.program ...$command.args } | complete)
    let status = if $run.exit_code == 0 { "executed" } else { "error" }

    let validation = if $validate {
      if $run.exit_code == 0 {
        let db_exists = ($db_path | path exists)
        let csv_match = (
          (($expected_nodes == null) or ($expected_nodes == $node_rows)) and
          (($expected_edges == null) or ($expected_edges == $edge_rows))
        )
        {
          status: (if $db_exists {
            if $csv_match { "ok" } else { "mismatch" }
          } else { "missing-database" })
          database: $db_path
          node_rows: $node_rows
          expected_nodes: $expected_nodes
          edge_rows: $edge_rows
          expected_edges: $expected_edges
        }
      } else {
        {
          status: "skipped"
          reason: "execution-error"
          node_rows: $node_rows
          expected_nodes: $expected_nodes
          edge_rows: $edge_rows
          expected_edges: $expected_edges
        }
      }
    } else {
      {
        status: "skipped"
        reason: "not-requested"
      }
    }

    [{
      plan: ($plan | path expand)
      database: $db_path
      script: $script_path
      status: $status
      exit_code: $run.exit_code
      stdout: ($run.stdout | default "")
      stderr: ($run.stderr | default "")
      validation: $validation
    }]
  } else {
    let validation = if $validate {
      {
        status: "csv-count"
        reason: "dry-run"
        node_rows: $node_rows
        expected_nodes: $expected_nodes
        edge_rows: $edge_rows
        expected_edges: $expected_edges
      }
    } else {
      { status: "skipped", reason: "not-requested" }
    }

    [{
      plan: ($plan | path expand)
      database: $db_path
      script: $script_path
      status: "dry-run"
      exit_code: null
      stdout: ""
      stderr: ""
      validation: $validation
    }]
  }

  $result
}
