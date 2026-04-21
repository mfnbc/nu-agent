# Tool schema metadata and validation helpers for nu-agent

use ../tools.nu *

def command-signatures [name: string] {
  let matches = (scope commands | where name == $name)

  if (($matches | length) == 0) {
    error make { msg: $"Unknown command: ($name)" }
  }

  ($matches | first | get signatures | get any)
}

def named-command-params [name: string] {
  (command-signatures $name)
  | where { |p| ($p.parameter_type == "named") or ($p.parameter_type == "switch") }
  | each { |p|
      let syntax = if $p.parameter_type == "switch" {
        "bool"
      } else {
        $p.syntax_shape | into string
      }
      {
        name: $p.parameter_name
        syntax: $syntax
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

export def build-tool-schema [] {
  let names = $TOOL_NAMES

  $names | each { |name|
    let spec = ($TOOL_REGISTRY | get $name)
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

export def canonical-tool-name [name: string] {
  $name | str replace --all "_" "-"
}

export def validate-call-args [call] {
  let name = (canonical-tool-name $call.name)
  let args = ($call.arguments | default {})
  let arg_type = ($args | describe)

  if not ($name in ($TOOL_REGISTRY | columns)) {
    error make { msg: $"Unknown tool: ($name)" }
  }

  let spec = ($TOOL_REGISTRY | get $name)
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

export def validate-calls [calls] {
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
