#!/usr/bin/env nu
# Smoke test for the Operator contract adapter, end-to-end via airun.
#
# Run from repo root:         nu scripts/smoke-operator.nu
# Or from inside scripts/:    nu smoke-operator.nu
#
# Exercises: airun → build-tool-schema → call-operator → coerce-json →
#            validate-calls → run-calls → invoke-tool dispatch.
#
# Uses the existing `list-files` whitelisted tool against the repo root as a
# safe, read-only check.

use ../mod.nu *

let task = "List the files in the current directory. Use the list-files tool with path \".\"."

print $"Task: ($task)"
print "Running airun ..."
print "---"

let results = (airun --task $task)

print $"Received ($results | length) result\(s\):"
$results | each { |r| print $"  ($r | to json)" }
print "---"

if (($results | length) == 0) {
  print "smoke: FAIL — airun returned no results"
  exit 1
}

# Verify shape: at least one result has a `tool` field (run-calls output format).
let has_tool_field = ($results | any { |r| "tool" in (try { $r | columns } catch { [] }) })
if $has_tool_field {
  print "smoke: OK"
} else {
  print "smoke: UNEXPECTED — results do not carry a tool field; review manually"
  exit 1
}
