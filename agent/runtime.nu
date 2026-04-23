# Runtime orchestration for nu-agent tool execution

use ../tools.nu *
use ./schema.nu [build-tool-schema canonical-tool-name validate-call-args validate-calls]
use ./llm.nu [call-llm-json parse-json-calls-safe]

def nu-target-path [call] {
  let name = (canonical-tool-name $call.name)

  match $name {
    "write-file" => { $call.arguments.path }
    "replace-in-file" => { $call.arguments.path }
    "propose-edit" => { $call.arguments.path }
    "apply-edit" => { $call.arguments.file }
    _ => { null }
  }
}

def nu-candidate-content [call result] {
  let name = (canonical-tool-name $call.name)

  match $name {
    "write-file" => { $call.arguments.content }
    "replace-in-file" => { open $call.arguments.path }
    "propose-edit" => { $result.preview.preview }
    "apply-edit" => { $call.arguments.after }
    _ => { null }
  }
}

def repair-nu-prompt [call, content: string, reason: string] {
  $"The previous tool output produced invalid Nushell syntax for a .nu file.\nTool call: (($call | to json))\nInvalid content: ($content)\nSyntax error: ($reason)\nReturn only a valid JSON array containing a single corrected tool call. Keep the same tool and target file, and fix only the Nushell syntax."
}

def repair-nu-call [call, content: string, reason: string, tools: list] {
  let prompt = (repair-nu-prompt $call $content $reason)
  let repaired = (call-llm-json $prompt $tools)

  validate-calls $repaired

  if (($repaired | length) != 1) {
    error make { msg: "Nushell syntax repair must return exactly one tool call" }
  }

  let repaired_call = ($repaired | first)
  let original_name = (canonical-tool-name $call.name)
  let repaired_name = (canonical-tool-name $repaired_call.name)

  if $original_name != $repaired_name {
    error make { msg: "Nushell syntax repair changed the tool name" }
  }

  let original_path = (nu-target-path $call)
  let repaired_path = (nu-target-path $repaired_call)

  if $original_path != $repaired_path {
    error make { msg: "Nushell syntax repair changed the target file" }
  }

  $repaired_call
}

def validate-nu-output [call, result, tools: list] {
  let path = (nu-target-path $call)

  if ($path == null) or (not ($path | str ends-with ".nu")) {
    $result
  } else {
    let content = (nu-candidate-content $call $result)
    let check = (check-nu-content $content)

    if ($check.status? | default "") == "ok" {
      $result
    } else {
      let repaired_call = (repair-nu-call $call $content $check.error $tools)
      let repaired_result = (invoke-tool $repaired_call)
      let repaired_content = (nu-candidate-content $repaired_call $repaired_result)
      let repaired_check = (check-nu-content $repaired_content)

      if ($repaired_check.status? | default "") == "ok" {
        $repaired_result
      } else {
        error make { msg: ($repaired_check.error | default "Nushell syntax repair failed") }
      }
    }
  }
}

def expected-call-count [task: string] {
  let t = ($task | str downcase)

  if ($t | str contains "exactly one tool call") {
    1
  } else if ($t | str contains "exactly two tool calls") {
    2
  } else if ($t | str contains "exactly three tool calls") {
    3
  } else if ($t | str contains "exactly four tool calls") {
    4
  } else if ($t | str contains "exactly five tool calls") {
    5
  } else {
    null
  }
}

def continue-prompt [task: string, executed: list] {
  $"Original request: ($task)\nAlready executed tool calls and results: (($executed | to json))\nEmit only the remaining tool calls needed to satisfy the original request. Preserve the original order. Output only a JSON array."
}

def invoke-tool [call] {
  let name = (canonical-tool-name $call.name)
  let args = $call.arguments

  match $name {
    "read-file" => { read-file --path $args.path }
    "write-file" => { write-file --path $args.path --content $args.content }
    "list-files" => { list-files --path $args.path }
    "search" => { search --pattern $args.pattern --path $args.path }
    "search-chunks" => { search-chunks --pattern $args.pattern --path $args.path }
    # inspect-rig-plan removed from canonical toolset; graph/rig plan inspection
    # is no longer part of the core runtime. Reimplement as an external opt-in
    # adapter if required.
    "inspect-chunk" => {
      let include_neighbors = ($args.neighbors? | default false)
      if $include_neighbors {
        inspect-chunk --path $args.path --id $args.id --neighbors
      } else {
        inspect-chunk --path $args.path --id $args.id
      }
    }
    "search-embedding-input" => { search-embedding-input --path $args.path --pattern $args.pattern --limit ($args.limit? | default 0) }
    "replace-in-file" => { replace-in-file --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "propose-edit" => { propose-edit --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "apply-edit" => { apply-edit --file $args.file --after $args.after }
    "check-nu-syntax" => { check-nu-syntax --path $args.path }
    "self-check" => { self-check }
    "resolve-command-doc" => { resolve-command-doc --name $args.name }
    "search-nu-concepts" => { search-nu-concepts --query $args.query --limit ($args.limit? | default 0) }
    _ => { error make { msg: $"Unknown tool: ($name)" } }
  }
}

def format-tool-output [call, result] {
  let result_type = ($result | describe)

  if ($result_type | str starts-with "record") {
    if "preview" in ($result | columns) {
      { tool: $call.name }
      | merge ($result | reject preview)
      | merge $result.preview
    } else {
      { tool: $call.name } | merge $result
    }
  } else {
    { tool: $call.name, result: $result }
  }
}

def run-tool [call, tools: list] {
  let result = (invoke-tool $call)
  let validated = (validate-nu-output $call $result $tools)

  format-tool-output $call $validated
}

def run-calls [calls, tools: list] {
  $calls | each { |c|
    validate-call-args $c

    run-tool $c $tools
  }
}

export def run-json [--calls: string] {
  let parsed = parse-json-calls-safe $calls

  let parsed_type = ($parsed | describe)
  if (not ($parsed_type | str starts-with "list")) and (not ($parsed_type | str starts-with "table")) {
    error make { msg: "nu-agent expected JSON array output from the model, but parsing did not produce a list" }
  }

  validate-calls $parsed
  let tools = build-tool-schema
  run-calls $parsed $tools
}

export def airun [--task: string] {
  let tools = build-tool-schema
  let calls = (call-llm-json $task $tools)
  validate-calls $calls
  let results = (run-calls $calls $tools)
  let expected = (expected-call-count $task)

  # One-shot continuation: if the model returned fewer calls than expected,
  # prompt it once more with the already-executed results. No further retry.
  if ($expected != null) and (($calls | length) < $expected) {
    let prompt = (continue-prompt $task $results)
    let calls2 = (call-llm-json $prompt $tools)
    validate-calls $calls2
    $results ++ (run-calls $calls2 $tools)
  } else {
    $results
  }
}
