export const TOOL_NAMES = [
  "read-file"
  "write-file"
  "list-files"
  "search"
  "replace-in-file"
  "propose-edit"
  "apply-edit"
]

export def tool-commands [] {
  let cmds = (scope commands)
  $TOOL_NAMES | each { |t| $cmds | where name == $t } | flatten
}

export def read-file [--path: string] {
  open $path
}

export def write-file [--path: string, --content: string] {
  $content | save $path
  { status: "ok", path: $path }
}

export def list-files [--path: string] {
  ls $path | select name type size
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
          $row.item | str replace $pattern $replacement
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

  $updated
  | str join (char nl)
  | save -f $path

  { file: $path, replacements: $count }
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
          $row.item | str replace $pattern $replacement
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
    preview: ($updated | str join (char nl))
  }
}

# Apply a previously proposed edit
export def "apply-edit" [--file: string, --after: string] {
  $after | save -f $file
  { file: $file, status: "applied" }
}
