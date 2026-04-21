# Enrichment flow helpers for nu-agent

use ../api.nu *
use ./json.nu [coerce-json]

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

export def validate-enrichment-output [output, schema] {
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
  let raw = (call-llm-content $prompt)

  try {
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
