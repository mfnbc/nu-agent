#!/usr/bin/env nu
# Smoke test for the thin LLM client.
#
# Run from repo root:        nu scripts/smoke-call-llm.nu
# Or from inside scripts/:   nu smoke-call-llm.nu
#
# The `use ../llm.nu *` below resolves relative to THIS script's location
# (scripts/ → ../ → repo root), not to the current working directory, so
# either invocation above works.

use ../llm.nu *

let messages = [
  { role: "system", content: "You are a helpful assistant. Respond concisely with one short sentence." }
  { role: "user", content: "Say 'hello from nu-agent' and nothing else." }
]

print "Calling llm.nu::call-llm ..."
let response = (call-llm $messages)
print "---"
print $response
print "---"

if (($response | str downcase) | str contains "hello from nu-agent") {
  print "smoke: OK"
} else {
  print "smoke: UNEXPECTED response content — review manually"
}
