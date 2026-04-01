use ./api.nu *
export use ./tools.nu *

const TOOL_SPECS = {
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
}

def command-signatures [name: string] {
  let matches = (scope commands | where name == $name)

  if (($matches | length) == 0) {
    error make { msg: $"Unknown command: ($name)" }
  }

  ($matches | first | get signatures | get any)
}

def named-command-params [name: string] {
  (command-signatures $name)
  | where parameter_type == "named"
  | each { |p|
      {
        name: $p.parameter_name
        syntax: ($p.syntax_shape | into string)
      }
    }
}

def syntax-shape->json-type [shape: string] {
  let s = ($shape | str downcase)

  if $s == "string" {
    "string"
  } else if $s == "any" {
    "string"
  } else if ($s == "int") or ($s == "integer") {
    "integer"
  } else if ($s == "float") or ($s == "number") {
    "number"
  } else if ($s == "bool") or ($s == "boolean") {
    "boolean"
  } else if ($s == "list") {
    "array"
  } else if ($s == "record") {
    "object"
  } else {
    error make { msg: $"Unsupported Nushell parameter type: ($shape)" }
  }
}

def value-matches-syntax [value, syntax: string] {
  let actual = ($value | describe)
  let expected = ($syntax | str downcase)

  if $expected == "any" {
    true
  } else if $expected == "string" {
    $actual | str starts-with "string"
  } else if ($expected == "int") or ($expected == "integer") {
    $actual | str starts-with "int"
  } else if ($expected == "float") or ($expected == "number") {
    ($actual | str starts-with "int") or ($actual | str starts-with "float")
  } else if ($expected == "bool") or ($expected == "boolean") {
    $actual | str starts-with "bool"
  } else if $expected == "list" {
    $actual | str starts-with "list"
  } else if $expected == "record" {
    $actual | str starts-with "record"
  } else {
    error make { msg: $"Unsupported Nushell parameter type: ($syntax)" }
  }
}

def build-tool-schema [] {
  let names = $TOOL_NAMES

  $names | each { |name|
    let spec = ($TOOL_SPECS | get $name)
    let required = $spec.required
    let allowed = $spec.allowed
    let param_specs = (named-command-params $name)

    let props = ($allowed | reduce -f {} { |p, acc|
      let matches = ($param_specs | where name == $p)
      let param = (if (($matches | length) > 0) { $matches | first } else { null })

      if $param == null {
        error make { msg: $"Missing signature metadata for tool '($name)' argument '($p)'" }
      }

      $acc | upsert $p {
        type: (syntax-shape->json-type $param.syntax)
        description: ($spec.argument_descriptions | get $p)
      }
    })

    {
      type: "function"
      function: {
        name: $name
        description: $spec.description
        parameters: {
          type: "object"
          properties: $props
          required: $required
        }
      }
    }
  }
}

def coerce-json [raw] {
  let t = ($raw | describe)

  if ($t | str starts-with "string") {
    $raw | from json
  } else {
    $raw
  }
}

def parse-json-calls-safe [raw] {
  try {
    coerce-json $raw
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    error make { msg: $"nu-agent expected JSON array output from the model, but parsing failed: ($reason)" }
  }
}

def repair-prompt [task: string, broken: string, reason: string] {
  $"Original request: ($task)\nThe previous assistant output was invalid JSON.\nOutput was: (($broken | into string))\nReason: ($reason)\nReturn only a valid JSON array. Fix the JSON and do not add any extra text."
}

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

def call-llm-json [task: string, tools: list] {
  let raw = (call-llm $task $tools)

  try {
    coerce-json $raw
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    let retry_task = (repair-prompt $task $raw $reason)
    let raw2 = (call-llm $retry_task $tools)

    try {
      coerce-json $raw2
    } catch {
      error make { msg: "LLM did not return parseable JSON array after retry" }
    }
  }
}

def enrichment-schema-parts [schema] {
  let schema_type = ($schema | describe)

  if not ($schema_type | str starts-with "record") {
    error make { msg: "Enrichment schema must be a record" }
  }

  let allowed = ($schema.allowed? | default null)

  if $allowed == null {
    error make { msg: "Enrichment schema must include an allowed list" }
  }

  let allowed_type = ($allowed | describe)
  if not ($allowed_type | str starts-with "list") {
    error make { msg: "Enrichment schema allowed field must be a list" }
  }

  let required = ($schema.required? | default [])
  let non_null = ($schema.non_null? | default [])

  if not (($required | describe) | str starts-with "list") {
    error make { msg: "Enrichment schema required field must be a list" }
  }

  if not (($non_null | describe) | str starts-with "list") {
    error make { msg: "Enrichment schema non_null field must be a list" }
  }

  let required_outside_allowed = ($required | where { |k| $k not-in $allowed })
  let non_null_outside_allowed = ($non_null | where { |k| $k not-in $allowed })

  if (($required_outside_allowed | length) > 0) {
    error make { msg: $"Enrichment schema required keys must be inside allowed: (($required_outside_allowed | str join ', '))" }
  }

  if (($non_null_outside_allowed | length) > 0) {
    error make { msg: $"Enrichment schema non_null keys must be inside allowed: (($non_null_outside_allowed | str join ', '))" }
  }

  { allowed: $allowed, required: $required, non_null: $non_null }
}

def validate-enrichment-output [output, schema] {
  let parts = (enrichment-schema-parts $schema)
  let allowed = $parts.allowed
  let required = $parts.required
  let non_null = $parts.non_null

  let output_type = ($output | describe)
  if not ($output_type | str starts-with "record") {
    error make { msg: "Enrichment output must be a JSON object" }
  }

  let keys = ($output | columns)
  let extra = ($keys | where { |k| $k not-in $allowed })
  let missing = ($required | where { |k| $k not-in $keys })
  let nulls = ($non_null | where { |k| ($k not-in $keys) or (($output | get $k) == null) })

  if (($extra | length) > 0) {
    error make { msg: $"Enrichment output contains extra keys: (($extra | str join ', '))" }
  }

  if (($missing | length) > 0) {
    error make { msg: $"Enrichment output is missing required keys: (($missing | str join ', '))" }
  }

  if (($nulls | length) > 0) {
    error make { msg: $"Enrichment output contains null or missing non-null keys: (($nulls | str join ', '))" }
  }

  $output
}

def enrichment-prompt [task: string, record, schema] {
  $"Task: ($task)\nInput record: (($record | to json))\nTarget schema: (($schema | to json))\nReturn only a valid JSON object that matches the target schema exactly. Do not add extra keys."
}

def enrichment-repair-prompt [task: string, record, schema, broken: string, reason: string] {
  $"Task: ($task)\nInput record: (($record | to json))\nTarget schema: (($schema | to json))\nThe previous answer was invalid.\nAnswer was: ($broken)\nReason: ($reason)\nReturn only a valid JSON object that matches the target schema exactly. Do not add extra keys."
}

def run-enrichment [task: string, record, schema] {
  let prompt = (enrichment-prompt $task $record $schema)
  mut raw = ""

  try {
    $raw = (call-llm-content $prompt)
    let parsed = (coerce-json $raw)
    validate-enrichment-output $parsed $schema
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    let repair_prompt = (enrichment-repair-prompt $task $record $schema $raw $reason)
    let repaired_raw = (call-llm-content $repair_prompt)
    let repaired_parsed = (coerce-json $repaired_raw)

    try {
      validate-enrichment-output $repaired_parsed $schema
    } catch { |repair_err|
      let repair_reason = ($repair_err.msg? | default ($repair_err | to text))
      error make { msg: $"Enrichment failed after retry: ($repair_reason)" }
    }
  }
}

export def enrich [--task: string, --record: string, --schema: string, --validate-only] {
  if (($task | default "" | str length) == 0) {
    error make { msg: "Missing required --task argument" }
  }

  if (($record | default "" | str length) == 0) {
    error make { msg: "Missing required --record argument" }
  }

  if (($schema | default "" | str length) == 0) {
    error make { msg: "Missing required --schema argument" }
  }

  let parsed_record = (coerce-json $record)
  let parsed_schema = (coerce-json $schema)

  if $validate_only {
    validate-enrichment-output $parsed_record $parsed_schema
  } else {
    run-enrichment $task $parsed_record $parsed_schema
  }
}

def canonical-tool-name [name: string] {
  $name | str replace --all "_" "-"
}

def validate-call-args [call] {
  let name = (canonical-tool-name $call.name)
  let args = ($call.arguments | default {})
  let arg_type = ($args | describe)

  if not ($name in ($TOOL_SPECS | columns)) {
    error make { msg: $"Unknown tool: ($name)" }
  }

  let spec = ($TOOL_SPECS | get $name)
  let allowed = $spec.allowed
  let required = $spec.required
  let param_specs = (named-command-params $name)

  if (not ($arg_type | str starts-with "record")) {
    error make { msg: $"Invalid arguments for tool '($name)'; expected an object" }
  }

  let arg_keys = ($args | columns)
  let missing = ($required | where { |p| $p not-in $arg_keys })

  if (($missing | length) > 0) {
    error make { msg: $"Missing required arguments for tool '($name)': (($missing | str join ', '))" }
  }

  let unknown = ($arg_keys | where { |k| $k not-in $allowed })

  if (($unknown | length) > 0) {
    error make { msg: $"Unknown arguments for tool '($name)': (($unknown | str join ', '))" }
  }

  let type_violations = ($arg_keys | each { |k|
      let matches = ($param_specs | where name == $k)
      let expected = (if (($matches | length) > 0) { $matches | first | get syntax } else { null })

      if $expected == null {
        null
      } else if not (value-matches-syntax ($args | get $k) $expected) {
        { argument: $k, expected: $expected, actual: (($args | get $k) | describe) }
      } else {
        null
      }
  } | compact)

  if (($type_violations | length) > 0) {
    error make { msg: $"Invalid argument types for tool '($name)': (($type_violations | to json))" }
  }
}

def validate-calls [calls] {
  let calls_type = ($calls | describe)

  if (not ($calls_type | str starts-with "list")) and (not ($calls_type | str starts-with "table")) {
    error make { msg: "Calls must be a list" }
  }

  for $c in $calls {
    let cols = ($c | columns)
    let name = (canonical-tool-name $c.name)

    if ("name" not-in $cols) or ("arguments" not-in $cols) {
      error make { msg: "Invalid call shape" }
    }

    if $name not-in $TOOL_NAMES {
      error make { msg: $"Unknown tool: ($c.name)" }
    }
  }
}

# Parse exact call-count hints from the task string. Caps at 5; prompts beyond
# that should not use this hint mechanism.
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
    "replace-in-file" => { replace-in-file --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "propose-edit" => { propose-edit --path $args.path --pattern $args.pattern --replacement $args.replacement }
    "apply-edit" => { apply-edit --file $args.file --after $args.after }
    "check-nu-syntax" => { check-nu-syntax --path $args.path }
    "self-check" => { self-check }
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
