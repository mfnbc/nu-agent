#!/usr/bin/env nu
use ./mod.nu *

export def main [] {
  let cases = [
    { name: "Prose with JSON inside", should_fail: true, input: "Here is your JSON.\n[{\"name\": \"list-files\", \"arguments\": {\"path\": \".\"}}]\nHope this helps!" }
    { name: "Hallucinated tool", should_fail: true, input: "[{\"name\": \"fake-tool\", \"arguments\": {}}]" }
    { name: "Missing required arg", should_fail: true, input: "[{\"name\": \"read-file\", \"arguments\": {}}]" }
    { name: "Markdown json fence", should_fail: true, input: "```json\n[{\"name\": \"list-files\", \"arguments\": {\"path\": \".\"}}]\n```" }
    { name: "Pure prose", should_fail: true, input: "I am unable to do that." }
  ]

  $cases | each { |case|
    let name = $case.name
    let should_fail = $case.should_fail
    let input = $case.input
    let result = (try { run-json --calls $input; "pass" } catch { "fail" })
    let expected = if $should_fail { "fail" } else { "pass" }

    if $result != $expected {
      print $"Failed test case: ($name). Expected=($expected), got=($result)"
      error make { msg: "Tests failed" }
    } else {
      print $"Passed test case: ($name)"
    }
  }
}
