export const TOOL_REGISTRY = {
  "read-file": {
    description: "Read a text file and return its contents."
    required: ["path"]
    allowed: ["path"]
    argument_descriptions: { path: "Path to the file to read." }
  }
  "write-file": {
    description: "Write content to a file, syntax-checking .nu files first."
    required: ["path", "content"]
    allowed: ["path", "content"]
    argument_descriptions: { path: "Path to write to.", content: "Text content to write." }
  }
  "list-files": {
    description: "List files and directories at a path."
    required: ["path"]
    allowed: ["path"]
    argument_descriptions: { path: "Directory or file path to inspect." }
  }
  "search": {
    description: "Search for a regex pattern in files under a path."
    required: ["pattern", "path"]
    allowed: ["pattern", "path"]
    argument_descriptions: { pattern: "Regex pattern to match.", path: "File or directory path to search." }
  }
  "search-chunks": {
    description: "Search ingested chunk NUON files for matching evidence."
    required: ["pattern", "path"]
    allowed: ["pattern", "path"]
    argument_descriptions: { pattern: "Regex pattern to match against chunk fields.", path: "Directory or .chunks.nuon file to search." }
  }
  "replace-in-file": {
    description: "Replace matching text in a file and preview the result."
    required: ["path", "pattern", "replacement"]
    allowed: ["path", "pattern", "replacement"]
    argument_descriptions: { path: "File to edit.", pattern: "Regex pattern to replace.", replacement: "Replacement text." }
  }
  "propose-edit": {
    description: "Preview a file edit without writing it."
    required: ["path", "pattern", "replacement"]
    allowed: ["path", "pattern", "replacement"]
    argument_descriptions: { path: "File to preview.", pattern: "Regex pattern to replace.", replacement: "Replacement text." }
  }
  "apply-edit": {
    description: "Apply a proposed file edit, syntax-checking .nu files first."
    required: ["file", "after"]
    allowed: ["file", "after"]
    argument_descriptions: { file: "File to update.", after: "Final edited file content." }
  }
  "check-nu-syntax": {
    description: "Check a Nushell file for syntax errors without executing it."
    required: ["path"]
    allowed: ["path"]
    argument_descriptions: { path: "Path to the .nu file to check." }
  }
  "self-check": {
    description: "Run local health checks for registered commands and source files."
    required: []
    allowed: []
    argument_descriptions: {}
  }
  "inspect-rig-plan": {
    description: "Inspect a Rig/FastEmbed LanceDB plan file."
    required: ["path"]
    allowed: ["path", "table", "limit"]
    argument_descriptions: {
      path: "Path to the Rig plan JSON file."
      table: "Optional table or job id to filter results."
      limit: "Optional maximum number of jobs to return."
    }
  }
  "inspect-chunk": {
    description: "Retrieve a specific chunk (and optional neighbors) from chunk JSONL files."
    required: ["path", "id"]
    allowed: ["path", "id", "neighbors"]
    argument_descriptions: {
      path: "Directory or .chunks.nuon file to inspect."
      id: "Chunk id to retrieve."
      neighbors: "Include previous/next chunks when present."
    }
  }
  "search-embedding-input": {
    description: "Search embedding_input JSONL records for matching text."
    required: ["path", "pattern"]
    allowed: ["path", "pattern", "limit"]
    argument_descriptions: {
      path: "Directory or .embedding_input.nuon file to search."
      pattern: "Regex pattern to match against embedding_input text."
      limit: "Optional maximum number of hits to return."
    }
  }
  "resolve-command-doc": {
    description: "Resolve exact command documentation from the locally ingested command map (or return informative error)."
    required: ["name"]
    allowed: ["name"]
    argument_descriptions: { name: "Command name to resolve (exact)." }
  }
  "search-nu-concepts": {
    description: "Search ingested concept vectors (fallback to JSONL scan) for relevant documentation evidence."
    required: ["query"]
    allowed: ["query", "limit"]
    argument_descriptions: {
      query: "Search text to match against ingested docs."
      limit: "Optional maximum number of results to return."
    }
  }
}

export const TOOL_NAMES = [
  "read-file"
  "write-file"
  "list-files"
  "search"
  "search-chunks"
  "replace-in-file"
  "propose-edit"
  "apply-edit"
  "check-nu-syntax"
  "self-check"
  "inspect-chunk"
  "search-embedding-input"
  "resolve-command-doc"
  "search-nu-concepts"
]

export def tool-commands [] {
  let cmds = (scope commands)

  $cmds | where { |c| $c.name in $TOOL_NAMES }
}

# Wrapper to call the resolve-command-doc script and return parsed JSON
export def resolve-command-doc [--name: string] {
  if (($name | default "") == "") {
    error make { msg: "Missing required --name argument" }
  }

  let result = (do { ^$nu.current-exe --no-config-file -c "use scripts/resolve-command-doc.nu; main --name \"$name\"" } | complete)
  if $result.exit_code != 0 {
    error make { msg: ($result.stderr | str trim) }
  }

  let out = ($result.stdout? | default "")
  if ($out | str length) == 0 {
    error make { msg: "resolve-command-doc produced no output" }
  }

  try { $out | from json } catch { error make { msg: "resolve-command-doc returned invalid JSON" } }
}

# Wrapper to call the search-nu-concepts script and return parsed JSON array
export def search-nu-concepts [--query: string, --limit: int = 0] {
  if (($query | default "") == "") {
    error make { msg: "Missing required --query argument" }
  }

  let cmd = if $limit > 0 { ^$nu.current-exe --no-config-file -c "use scripts/search-nu-concepts.nu; main --query \"$query\" --limit $limit" } else { ^$nu.current-exe --no-config-file -c "use scripts/search-nu-concepts.nu; main --query \"$query\"" }
  let result = (do { $cmd } | complete)

  if $result.exit_code != 0 {
    error make { msg: ($result.stderr | str trim) }
  }

  let out = ($result.stdout? | default "")
  if ($out | str length) == 0 {
    error make { msg: "search-nu-concepts produced no output" }
  }

  try { $out | from json } catch { error make { msg: "search-nu-concepts returned invalid JSON" } }
}

export def read-file [--path: string] {
  if ($path == null) or (($path | str trim) == "") {
    error make { msg: "Missing required path for read-file" }
  } else if not ($path | path exists) {
    error make { msg: $"File not found: ($path)" }
  } else {
    open $path
  }
}

export def write-file [--path: string, --content: string] {
  if ($path | str ends-with ".nu") {
    let check = (check-nu-content $content)

    if ($check.status? | default "") == "ok" {
      $content | save -f $path
      { status: "ok", file: $path }
    } else {
      let try_path = $"($path).try"
      $content | save -f $try_path
      { status: "syntax-error", file: $path, try_path: $try_path, error: $check.error }
    }
  } else {
    $content | save -f $path
    { status: "ok", file: $path }
  }
}

def edit-preview [lines: list<string>] {
  let count = ($lines | length)

  if $count <= 80 {
    {
      preview: ($lines | str join (char nl)),
      preview_lines: $lines,
      line_count: $count,
      truncated: false
    }
  } else {
    let head = ($lines | first 40)
    let tail = ($lines | last 40)
    {
      preview: (($head ++ ["..."] ++ $tail) | str join (char nl)),
      preview_lines: ($head ++ ["..."] ++ $tail),
      line_count: $count,
      truncated: true
    }
  }
}

export def list-files [--path: string] {
  if ($path == null) or (($path | str trim) == "") {
    error make { msg: "Missing required path for list-files" }
  } else if not ($path | path exists) {
    error make { msg: $"Path not found: ($path)" }
  } else {
    ls $path | select name type size
  }
}

export def search [--pattern: string, --path: string] {
  # Pure Nushell search using pipelines (idiomatic)
  let t = ($path | path type)

  if $t == 'dir' {
    glob $"($path)/**/*"
    | where { |f| (($f | path type) == 'file') and not ($f | str contains ".git/") and not ($f =~ '\.(png|jpg|ico)$') }
    | each { |f|
        try {
          open $f
          | lines
          | enumerate
          | where ($it.item =~ $pattern)
          | each { |m|
              {
                file: $f,
                line: ($m.index + 1),
                text: $m.item
              }
            }
        } catch { [] }
      }
    | flatten
  } else {
    try {
      open $path
      | lines
      | enumerate
      | where ($it.item =~ $pattern)
      | each { |m|
          {
            file: $path,
            line: ($m.index + 1),
            text: $m.item
          }
        }
    } catch { [] }
  }
}

export def "search-chunks" [--path: string, --pattern: string] {
  if ($path == null) or (($path | str trim) == "") {
    error make { msg: "Missing required path for search-chunks" }
  }

  if ($pattern == null) or (($pattern | str trim) == "") {
    error make { msg: "Missing required pattern for search-chunks" }
  }

  let input_type = ($path | path type)
  let files = if $input_type == 'dir' {
    glob $"($path)/**/*.chunks.nuon" | sort
  } else if ($path | str ends-with ".chunks.nuon") {
    [$path]
  } else {
    error make { msg: "search-chunks expects a directory or a .chunks.nuon file" }
  }

  if (($files | length) == 0) {
    error make { msg: $"No chunk NUON files found under: ($path)" }
  }

  $files
  | each { |file|
      try {
        let rows = if ($file | str ends-with ".msgpack") {
          open $file | from msgpack
        } else {
          open $file | from nuon
        }

        $rows
        | each { |chunk|
            let searchable = [
              { field: "id", value: $chunk.id }
              { field: "identity.source", value: $chunk.identity.source }
              { field: "identity.path", value: $chunk.identity.path }
              { field: "identity.checksum", value: $chunk.identity.checksum }
              { field: "hierarchy.title", value: $chunk.hierarchy.title }
              { field: "hierarchy.heading_path", value: ($chunk.hierarchy.heading_path | str join " > ") }
              { field: "taxonomy.chunk_type", value: ($chunk.taxonomy.chunk_type | into string) }
              { field: "taxonomy.commands", value: ($chunk.taxonomy.commands | str join " ") }
              { field: "taxonomy.tags", value: ($chunk.taxonomy.tags | str join " ") }
              { field: "data.content", value: $chunk.data.content }
              { field: "data.code_blocks", value: ($chunk.data.code_blocks | each { |block| $block.code } | str join "\n") }
              { field: "data.links", value: ($chunk.data.links | str join " ") }
              { field: "embedding_input", value: $chunk.embedding_input }
            ]

            let matched = ($searchable | where { |field| ($field.value | default "") =~ $pattern })

            if (($matched | length) > 0) {
              {
                file: $file,
                chunk_id: $chunk.id,
                matched_fields: ($matched | get field),
                chunk: $chunk
              }
            } else {
              null
            }
        } | compact
      } catch { [] }
    }
  | flatten
}

export def "inspect-rig-plan" [--path: string, --table: string = "", --limit: int = 0] {
  if (($path | default "" | str trim | str length) == 0) {
    error make { msg: "Missing required plan path" }
  }

  if not ($path | path exists) {
    error make { msg: $"Rig plan not found: ($path)" }
  }

  let plan_path = ($path | path expand)
  let plan = (open --raw $plan_path | from json)
  let jobs_all = ($plan.jobs? | default [])
  let filtered = if (($table | str length) > 0) {
    $jobs_all | where { |job|
      (($job.lancedb_table? | default "") == $table) or (($job.id? | default "") == $table)
    }
  } else {
    $jobs_all
  }

  let limited = if $limit > 0 { $filtered | take $limit } else { $filtered }

  {
    plan: $plan_path
    lancedb_dir: ($plan.lancedb_dir? | default null)
    job_total: ($filtered | length)
    truncated: (if ($limit > 0) { ($filtered | length) > $limit } else { false })
    jobs: $limited
  }
}

# Graph import planning functionality was removed. If you need similar features,
# reimplement them in a separate adapter repository and call it from this project
# as an external opt-in step.

export def "inspect-chunk" [--path: string, --id: string, --neighbors] {
  if (($path | default "" | str trim | str length) == 0) {
    error make { msg: "Missing required path" }
  }

  if (($id | default "" | str trim | str length) == 0) {
    error make { msg: "Missing required chunk id" }
  }

  let input_type = ($path | path type)
  let files = if $input_type == 'dir' {
    glob $"($path)/**/*.chunks.nuon" | sort
  } else if ($path | str ends-with ".chunks.nuon") {
    [$path]
  } else {
    error make { msg: "inspect-chunk expects a directory or a .chunks.nuon file" }
  }

  if (($files | length) == 0) {
    error make { msg: $"No chunk NUON files found under: ($path)" }
  }

  let found = (
    $files
    | each { |file|
        let chunks = (
          if ($file | str ends-with ".msgpack") {
            open $file | from msgpack
          } else {
            open $file | from nuon
          }
        )

        let indexed = ($chunks | enumerate)
        let matches = (
          $indexed
          | where { |row| ($row.item.id? | default "") == $id }
        )

        if (($matches | length) > 0) {
          let hit = ($matches | first)
          let idx = $hit.index
          let chunk = $hit.item

          let previous = if ($neighbors and $idx > 0) {
            $chunks | get ($idx - 1)
          } else {
            null
          }

          let next = if ($neighbors and $idx < (($chunks | length) - 1)) {
            $chunks | get ($idx + 1)
          } else {
            null
          }

          {
            file: $file
            chunk_index: $idx
            chunk: $chunk
            previous: $previous
            next: $next
          }
        } else {
          null
        }
      }
    | compact
  )

  if (($found | length) == 0) {
    error make { msg: $"Chunk id not found: ($id)" }
  }

  $found | first
}

export def "search-embedding-input" [--path: string, --pattern: string, --limit: int = 0] {
  if (($path | default "" | str trim | str length) == 0) {
    error make { msg: "Missing required path" }
  }

  if (($pattern | default "" | str trim | str length) == 0) {
    error make { msg: "Missing required pattern" }
  }

  let input_type = ($path | path type)
  let files = if $input_type == 'dir' {
    glob $"($path)/**/*.embedding_input.nuon" | sort
  } else if ($path | str ends-with ".embedding_input.nuon" ) or ($path | str ends-with ".embedding_input.msgpack") {
    [$path]
  } else {
    error make { msg: "search-embedding-input expects a directory or a .embedding_input.nuon/.msgpack file" }
  }

  if (($files | length) == 0) {
    error make { msg: $"No embedding_input NUON/MSGPACK files found under: ($path)" }
  }

  let hits = (
    $files
    | each { |file|
        try {
          if ($file | str ends-with ".msgpack") {
            # Use Nushell's native msgpack support to decode binary to structured data
            open $file | from msgpack
            | each { |record|
                if (($record.embedding_input? | default "") =~ $pattern) {
                  {
                    file: $file
                    id: ($record.id? | default null)
                    embedding_input: $record.embedding_input
                  }
                } else {
                  null
                }
              }
            | compact
          } else {
            open --raw $file
            | lines
            | where { |line| ($line | str trim) != "" }
            | each { |line|
                let record = ($line | from json)
                if (($record.embedding_input? | default "") =~ $pattern) {
                  {
                    file: $file
                    id: ($record.id? | default null)
                    embedding_input: $record.embedding_input
                  }
                } else {
                  null
                }
              }
            | compact
          }
        } catch { [] }
      }
    | flatten
  )

  let limited = if $limit > 0 { $hits | take $limit } else { $hits }

  {
    hits: $limited
    total: ($hits | length)
    truncated: (if $limit > 0 { ($hits | length) > $limit } else { false })
  }
}

export def "replace-in-file" [--path: string, --pattern: string, --replacement: string] {
  if not ($path | path exists) {
    error make { msg: $"File not found: ($path)" }
  }

  let original = (open $path | lines)

  let updated = (
    $original
    | enumerate
    | upsert item { |row|
        if ($row.item =~ $pattern) {
          $row.item | str replace --regex $pattern $replacement
        } else {
          $row.item
        }
      }
    | get item
  )

  let count = (
    $original
    | zip $updated
    | where { |r| $r.0 != $r.1 }
    | length
  )

  let content = ($updated | str join (char nl))

  if ($path | str ends-with ".nu") {
    let check = (check-nu-content $content)

    if ($check.status? | default "") == "ok" {
      $content | save -f $path
      { file: $path, replacements: $count, status: "ok", preview: (edit-preview $updated) }
    } else {
      let try_path = $"($path).try"
      $content | save -f $try_path
      { file: $path, replacements: $count, status: "syntax-error", try_path: $try_path, error: $check.error, preview: (edit-preview $updated) }
    }
  } else {
    $content | save -f $path
    { file: $path, replacements: $count, status: "ok", preview: (edit-preview $updated) }
  }
}

# Propose an edit without writing. Returns before/after and change count.
export def "propose-edit" [--path: string, --pattern: string, --replacement: string] {
  if not ($path | path exists) {
    error make { msg: $"File not found: ($path)" }
  }

  let original = (open $path | lines)

  let updated = (
    $original
    | enumerate
    | upsert item { |row|
        if ($row.item =~ $pattern) {
          $row.item | str replace --regex $pattern $replacement
        } else {
          $row.item
        }
      }
    | get item
  )

  let count = (
    $original
    | zip $updated
    | where { |r| $r.0 != $r.1 }
    | length
  )

  {
    file: $path,
    replacements: $count,
    preview: (edit-preview $updated)
  }
}

# Apply a previously proposed edit
export def "apply-edit" [--file: string, --after: string] {
  if ($file | str ends-with ".nu") {
    let check = (check-nu-content $after)

    if ($check.status? | default "") == "ok" {
      $after | save -f $file
      { file: $file, status: "ok" }
    } else {
      let try_path = $"($file).try"
      $after | save -f $try_path
      { file: $file, status: "syntax-error", try_path: $try_path, error: $check.error }
    }
  } else {
    $after | save -f $file
    { file: $file, status: "ok" }
  }
}

# Check Nushell file syntax without executing it
export def "check-nu-syntax" [--path: string] {
  if not ($path | path exists) {
    error make { msg: $"File not found: ($path)" }
  }

  let result = (do { ^$nu.current-exe --no-config-file -c $"use ($path)" } | complete)
  if $result.exit_code == 0 {
    { status: "ok", file: $path, message: "No syntax errors found." }
  } else {
    { status: "syntax-error", file: $path, error: ($result.stderr | str trim) }
  }
}

export def check-nu-content [content: string] {
  let temp_dir = ($env.TMPDIR? | default "/tmp")
  let temp = ($temp_dir | path join "nu-agent-syntax-check.nu")
  $content | save -f $temp

  let result = (check-nu-syntax --path $temp)

  if ($temp | path exists) {
    rm $temp
  }

  $result
}

export def self-check [] {
  let expected_tools = $TOOL_NAMES
  let commands = (scope commands | get name)

  let missing_tools = ($expected_tools | where { |t| not ($commands | any { |c| $c == $t }) })

  let forbidden = ["jq" "grep" "sed" "awk" "patch"]
  let files = (glob "**/*.nu")

  let token_violations = ($files | each { |f|
    let contents = (open $f)
    $forbidden | each { |cmd|
      let pattern = (['(^|\s|\|)', $cmd, '(\s|$|\|)'] | str join)
      if ($contents =~ $pattern) {
        { file: $f, token: $cmd }
      } else {
        null
      }
    }
  } | flatten | compact)

  let syntax_results = ($files | each { |f|
    let result = (check-nu-syntax --path $f)
    {
      file: $f,
      status: $result.status,
      error: ($result.error? | default null)
    }
  })

  let syntax_failures = ($syntax_results | where status != "ok")

  let overall_status = if (($missing_tools | length) == 0) and (($token_violations | length) == 0) and (($syntax_failures | length) == 0) {
    "ok"
  } else {
    "error"
  }

  {
    status: $overall_status,
    checks: [
      { check: "commands-present", status: (if (($missing_tools | length) == 0) { "ok" } else { "error" }), missing: $missing_tools }
      { check: "blocked-tokens", status: (if (($token_violations | length) == 0) { "ok" } else { "error" }), violations: $token_violations }
      { check: "syntax-health", status: (if (($syntax_failures | length) == 0) { "ok" } else { "error" }), files: $syntax_results }
    ]
  }
}
