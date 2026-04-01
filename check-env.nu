#!/usr/bin/env nu
use ./tool-registry.nu *

export def main [] {
  let commands = (scope commands | get name)
  let expected_tools = (get-tools | get name)

  let missing_tools = ($expected_tools | where { |t| not ($commands | any { |c| $c == $t }) })
  
  if ($missing_tools | length) > 0 {
    print $"Warning: The following tools are not available as commands: ($missing_tools)"
  } else {
    print "Success: All expected tools are registered."
  }

  let forbidden = ["jq" "grep" "sed" "awk" "patch"]
  let files = (glob "**/*.nu" | where { |f| not ($f | str ends-with "check-env.nu") })
  
  let violations = ($files | each { |f|
    let contents = (open $f)
    $forbidden | each { |cmd|
      let pattern = (['(^|\s|\|)', $cmd, '(\s|$|\|)'] | str join)
      if ($contents =~ $pattern) {
        { file: $f, cmd: $cmd }
      } else {
        null
      }
    }
  } | flatten | compact)

  if ($violations | length) > 0 {
    print "Warning: Found forbidden external commands in .nu files:"
    print $violations
  } else {
    print "Success: No forbidden external commands found."
  }
}