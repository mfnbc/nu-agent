export const TOOL_NAMES = [
  "read-file"
  "write-file"
  "list-files"
  "search"
  "replace-in-file"
  "propose-edit"
  "apply-edit"
  "check-nu-syntax"
  "self-check"
]

export def tool-commands [] {
  let cmds = (scope commands)

  $cmds | where { |c| $TOOL_NAMES | any { |name| $name == $c.name } }
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
      { status: "ok", path: $path }
    } else {
      let try_path = $"($path).try"
      $content | save -f $try_path
      { status: "syntax-error", path: $path, try_path: $try_path, error: $check.error }
    }
  } else {
    $content | save -f $path
    { status: "ok", path: $path }
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
      preview: (($head ++ ["..." ] ++ $tail) | str join (char nl)),
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
    | where { |f| (($f | path type) == 'file') and not ($f | str contains ".git/") and not ($f | str ends-with ".png") and not ($f | str ends-with ".jpg") and not ($f | str ends-with ".ico") }
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
      { file: $file, status: "applied" }
    } else {
      let try_path = $"($file).try"
      $after | save -f $try_path
      { file: $file, status: "syntax-error", try_path: $try_path, error: $check.error }
    }
  } else {
    $after | save -f $file
    { file: $file, status: "applied" }
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
