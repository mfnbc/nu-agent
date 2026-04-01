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

  print "Passed schema validation smoke test."
}
