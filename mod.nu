use ./tool-registry.nu *
use ./api.nu *
use ./tools.nu *

def build-tool-schema [] {
  let cmds = tool-commands

  $cmds | each { |c|
    let params = ($c.signature.parameters? | default [])

    let props = ($params | each { |p|
      { ($p.name): { type: "string" } }
    } | reduce -f {} { |it, acc| $acc | merge $it })

    let required = ($params | where optional == false | get name)

    {
      type: "function",
      function: {
        name: $c.name,
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
    ($raw | into string) | from json
  } else {
    $raw
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

def run-calls [calls] {
  $calls | each { |c|
    {
      tool: $c.name,
      result: (invoke-tool $c)
    }
  }
}

export def run-json [--calls: string] {
  let parsed = parse-json-calls $calls
  validate-calls $parsed
  run-calls $parsed
}

export def main [--task: string] {
  let tools = build-tool-schema
  let raw = call-llm $task $tools
  let calls = parse-json-calls $raw
  validate-calls $calls
  run-calls $calls
}
