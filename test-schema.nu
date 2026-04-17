#!/usr/bin/env nu
use ./mod.nu *

export def main [] {
  let good = (try { run-json --calls '[{"name":"write-file","arguments":{"path":"/tmp/nu-agent-schema.nu","content":"def main [] { print \"ok\" }"}}]'; "pass" } catch { "fail" })
  if $good != "pass" {
    error make { msg: "Expected valid write-file schema case to pass" }
  }

  let bad = (try { run-json --calls '[{"name":"write-file","arguments":{"path":"/tmp/nu-agent-schema.nu","content":123}}]'; "pass" } catch { "fail" })
  if $bad != "fail" {
    error make { msg: "Expected invalid write-file schema case to fail" }
  }

  let search_hits = (try {
    run-json --calls '[{"name":"search-chunks","arguments":{"path":"build/tmp-ingest/README.chunks.jsonl","pattern":"Enrichment Contract"}}]'
  } catch { |err|
    print $err.msg?
    error make { msg: "Expected search-chunks to be exposed in the tool schema" }
  })

  if (($search_hits | length) == 0) {
    error make { msg: "Expected search-chunks schema call to return evidence" }
  }

  print "Passed schema validation smoke test."
}
