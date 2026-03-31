#!/usr/bin/env nu
use ./mod.nu *

export def main [] {
  let cases = [
    {
      name: "Prose with JSON inside",
      input: "Here is your JSON.\n[{\"name\": \"list-files\", \"arguments\": {\"path\": \".\"}}]\nHope this helps!",
      valid: true
    },
    {
      name: "Hallucinated tool",
      input: "[{\"name\": \"fake-tool\", \"arguments\": {}}]",
      valid: false
    },
    {
      name: "Missing required arg",
      input: "[{\"name\": \"read-file\", \"arguments\": {}}]",
      valid: false
    },
    {
      name: "Markdown json fence",
      input: "```json\n[{\"name\": \"list-files\", \"arguments\": {\"path\": \".\"}}]\n```",
      valid: true
    },
    {
      name: "Pure prose",
      input: "I am unable to do that.",
      valid: false
    }
  ]

  $cases | each { |case|
    let result = (try { run-json --calls $case.input; "pass" } catch { "fail" })
    let ok = if $case.valid { $result == "pass" } else { $result == "fail" }
    if not $ok {
      print $"Failed test case: ($case.name) (Expected ($case.valid), but validation returned ($result))"
      error make { msg: "Tests failed" }
    } else {
      print $"Passed test case: ($case.name)"
    }
  }
}