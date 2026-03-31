use ./tool-registry.nu *
use ./api.nu *
use ./tools.nu *

const TOOL_SPECS = {
  "read-file": { required: [path], allowed: [path] }
  "write-file": { required: [path, content], allowed: [path, content] }
  "list-files": { required: [path], allowed: [path] }
  "search": { required: [pattern, path], allowed: [pattern, path] }
  "replace-in-file": { required: [path, pattern, replacement], allowed: [path, pattern, replacement] }
  "propose-edit": { required: [path, pattern, replacement], allowed: [path, pattern, replacement] }
  "apply-edit": { required: [file, after], allowed: [file, after] }
}

def build-tool-schema [] {
  $TOOL_SPECS | transpose name spec | each { |row|
    let required = $row.spec.required
    let allowed = $row.spec.allowed

    let props = ($allowed | each { |p| { ($p): { type: "string" } } } | reduce -f {} { |it, acc| $acc | merge $it })

    {
      type: "function",
      function: {
        name: $row.name,
        parameters: {
          type: "object",
          properties: $props,
          required: $required
        }
      }
    }
  }
}

def parse-json-calls [raw] {
  let t = ($raw | describe)

  if ($t | str starts-with "string") {
    let text = ($raw | into string | str trim)

    let direct = (if ($text | str starts-with "[") { "yes" } else { "no" })
    let candidate = $text
    let parsed_direct = (if $direct == "yes" { $candidate | from json } else { [] })

    if $direct == "yes" {
      $parsed_direct
    } else {
      let start = ($text | str index-of "[")
      let end = ($text | str index-of -e "]")

      if $start < 0 or $end < 0 or $end < $start {
        error make { msg: "LLM did not return parseable JSON array" }
      }

      let extracted = ($text | str substring $start..$end)
      let candidate = $extracted
      let parsed = ($candidate | from json)

      $parsed
    }
  } else {
    $raw
  }
}

def validate-call-args [call] {
  let name = $call.name
  let args = ($call.arguments | default {})
  let arg_type = ($args | describe)

  if not ($TOOL_SPECS | columns | any { |k| $k == $name }) {
    error make { msg: $"Unknown tool: ($name)" }
  }

  let spec = ($TOOL_SPECS | get $name)
  let allowed = $spec.allowed
  let required = $spec.required

  if (not ($arg_type | str starts-with "record")) {
    error make { msg: $"Invalid arguments for tool '($name)'; expected an object" }
  }

  let arg_keys = ($args | columns)
  let missing = ($required | where { |p| not ($arg_keys | any { |k| $k == $p }) })

  if (($missing | length) > 0) {
    error make { msg: $"Missing required arguments for tool '($name)': (($missing | str join ', '))" }
  }

  let unknown = ($arg_keys | where { |k| not ($allowed | any { |a| $a == $k }) })

  if (($unknown | length) > 0) {
    error make { msg: $"Unknown arguments for tool '($name)': (($unknown | str join ', '))" }
  }
}

def validate-calls [calls] {
  let calls_type = ($calls | describe)

  if (not ($calls_type | str starts-with "list")) and (not ($calls_type | str starts-with "table")) {
    error make { msg: "Calls must be a list" }
  }

  let allowed = $TOOLS

  $calls | each { |c|
    let cols = ($c | columns)

    if (not ($cols | any { |k| $k == "name" })) or (not ($cols | any { |k| $k == "arguments" })) {
      error make { msg: "Invalid call shape" }
    }

    if not ($allowed | any { |a| $a == $c.name }) {
      error make { msg: $"Unknown tool: ($c.name)" }
    }
  }
}

def invoke-tool [call] {
  let name = $call.name
  let args = $call.arguments

  match $name {
    "read-file" => { read-file --path $args.path }
    "write-file" => { write-file --path $args.path --content $args.content }
    "list-files" => { list-files --path $args.path }
    "search" => { search --pattern $args.pattern --path $args.path }
    "replace-in-file" => { replace-in-file --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "propose-edit" => { propose-edit --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "apply-edit" => { apply-edit --file $args.file --after $args.after }
    _ => { error make { msg: $"Unknown tool: ($name)" } }
  }
}

def format-tool-output [call] {
  let result = (invoke-tool $call)
  let result_type = ($result | describe)

  if ($result_type | str starts-with "record") {
    if (($result | columns) | any { |c| $c == "before" }) and (($result | columns) | any { |c| $c == "after" }) {
      {
        tool: $call.name
        file: ($result.file? | default null)
        replacements: ($result.replacements? | default null)
        preview: $result.after
      }
    } else {
      { tool: $call.name } | merge $result
    }
  } else {
    { tool: $call.name, result: $result }
  }
}

def run-calls [calls] {
  $calls | each { |c|
    validate-call-args $c

    format-tool-output $c
  }
}

export def run-json [--calls: string] {
  let parsed = parse-json-calls $calls
  validate-calls $parsed
  run-calls $parsed
}

export def airun [--task: string] {
  let tools = build-tool-schema
  let raw = call-llm $task $tools
  let calls = parse-json-calls $raw
  validate-calls $calls
  run-calls $calls
}
