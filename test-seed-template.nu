#!/usr/bin/env nu
use ./mod.nu *

export def main [] {
  let record = {
    surface: "אֲנִי"
    confidence: "guessing"
  }

  let prompt = (seed-prompt $record)
  if not ($prompt | str contains "paa_root") {
    error make { msg: "Seed prompt is missing expected guidance" }
  }

  let validated = (try {
    enrich --task "seed token layer" --record ($record | to json) --schema ((token-seed-schema) | to json) --validate-only
  } catch { |err|
    error make { msg: ($err.msg? | default "Seed schema validation failed") }
  })

  if (($validated | describe) | str starts-with "record") {
    print "Passed seed template smoke test."
  } else {
    error make { msg: "Expected validation to return a record" }
  }
}
