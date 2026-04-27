# Contract execution engine.
#
# Reads a contract TOML, dispatches by action verb. Consult is the only
# verb implemented today: build [system, user] messages, call llm.nu, return
# the response prose. Other verbs error until their execution shapes land.

use ./llm.nu *

export def consult [contract: string, prompt: string] {
  let c = (open $contract)
  if $c.action.verb != "Consult" {
    error make { msg: $"engine: only 'Consult' verb is implemented; got '($c.action.verb)' in ($contract)" }
  }
  let messages = [
    { role: "system", content: $c.prompt.system }
    { role: "user", content: $prompt }
  ]
  call-llm $messages
}
