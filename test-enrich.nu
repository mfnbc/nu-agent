#!/usr/bin/env nu
use ./mod.nu *

export def main [] {
  let schema = '{"allowed":["exercise","reps"],"required":["exercise"],"non_null":["exercise"]}'
  let record = '{"exercise":"squat","reps":5}'

  let result = (try {
    enrich --task "annotate workout" --record $record --schema $schema --validate-only
  } catch { |err|
    print $err.msg?
    error make { msg: "Expected enrichment entrypoint to accept inputs" }
  })

  if (($result | describe) | str starts-with "record") {
    print "Passed enrich smoke test."
  } else {
    error make { msg: "Expected enrichment to return a record" }
  }
}
