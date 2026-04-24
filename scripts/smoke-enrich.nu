#!/usr/bin/env nu
# Smoke test for the Enrichment contract adapter (agent/enrichment.nu).
#
# Run from repo root:         nu scripts/smoke-enrich.nu
# Or from inside scripts/:    nu smoke-enrich.nu
#
# Exercises: enrich → enrichment-user-prompt → call-llm → coerce-json →
#            validate-enrichment-output.
#
# Requires: an LLM endpoint reachable at the hardcoded CHAT_URL in llm.nu.

use ../agent/enrichment.nu *

let task = "Label this exercise as one of: strength, cardio, mobility."
let record = '{"exercise":"squat","reps":5}'
let schema = '{"allowed":["label","notes"],"required":["label"],"non_null":["label"]}'

print $"Task:   ($task)"
print $"Record: ($record)"
print $"Schema: ($schema)"
print "Calling enrich ..."
print "---"

let result = (enrich --task $task --record $record --schema $schema)

print $"Result: (($result | to json))"
print "---"

# If we got here, enrich succeeded and the result already passed
# validate-enrichment-output. Print the label as final confirmation.
print $"smoke: OK — label = \"($result.label)\""
