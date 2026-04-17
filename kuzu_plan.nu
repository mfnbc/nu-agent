export def kuzu-plan [
  manifest: string
  --out-dir: string = "build/kuzu-plan"
  --out: string = ""
] {
  if ((($manifest | default "") | str trim | str length) == 0) {
    error make { msg: "manifest path is required" }
  }

  if not ($manifest | path exists) {
    error make { msg: $"Manifest not found: ($manifest)" }
  }

  mkdir $out_dir

  let manifest_abs = ($manifest | path expand)
  let out_abs = ($out_dir | path expand)

  let data = (open --raw $manifest_abs | from json)
  let files = ($data.files? | default [])

  if (($files | length) == 0) {
    error make { msg: "Manifest contains no file summaries" }
  }

  let per_file = (
    $files
    | each { |item|
        let chunk_path = ($item.output? | default null)
        if $chunk_path == null {
          error make { msg: $"Manifest entry missing chunk output: ($item | to json)" }
        }

        if not ($chunk_path | path exists) {
          error make { msg: $"Chunk file not found: ($chunk_path)" }
        }

        let source = ($item.source? | default null)
        let chunks = (
          open --raw $chunk_path
          | lines
          | where { |line| ($line | str trim) != "" }
          | each { |line| $line | from json }
        )

        let nodes = (
          $chunks
          | each { |chunk|
              let heading = ($chunk.hierarchy.heading_path? | default [] | str join " > ")
              let commands = ($chunk.taxonomy.commands? | default [] | str join " ")
              {
                chunk_id: $chunk.id
                source: $source
                path: ($chunk.identity.path? | default null)
                checksum: ($chunk.identity.checksum? | default null)
                title: ($chunk.hierarchy.title? | default null)
                heading_path: $heading
                chunk_type: ($chunk.taxonomy.chunk_type? | into string)
                commands: $commands
                parent_id: ($chunk.hierarchy.parent_id? | default null)
                order: ($chunk.hierarchy.order? | default null)
              }
            }
        )

        let edges = (
          $chunks
          | each { |chunk|
              let parent_id = ($chunk.hierarchy.parent_id? | default null)
              if $parent_id != null {
                {
                  parent_id: $parent_id
                  child_id: $chunk.id
                  source: $source
                  path: ($chunk.identity.path? | default null)
                }
              } else {
                null
              }
            }
          | compact
        )

        {
          nodes: $nodes
          edges: $edges
        }
      }
  )

  let nodes = ($per_file | get nodes | flatten)
  let edges = ($per_file | get edges | flatten)

  let nodes_path = ($out_abs | path join "nodes.csv")
  let edges_path = ($out_abs | path join "edges.csv")

  (
    $nodes
    | select chunk_id source path checksum title heading_path chunk_type commands parent_id order
    | to csv
  ) | save -f $nodes_path

  (
    $edges
    | select parent_id child_id source path
    | to csv
  ) | save -f $edges_path

  let sources = (
    $nodes
    | where { |row| $row.source != null }
    | get source
    | sort
    | uniq
  )

  let plan = {
    manifest: $manifest_abs
    out_dir: $out_abs
    nodes_csv: $nodes_path
    edges_csv: $edges_path
    node_count: ($nodes | length)
    edge_count: ($edges | length)
    sources: $sources
  }

  if ((($out | default "") | str trim | str length) > 0) {
    let plan_path = ($out | path expand)
    $plan | to json | save -f $plan_path
  }

  $plan
}
