# Contract execution engine.
#
# Reads a contract TOML, dispatches by action verb. Consult is the only verb
# implemented today: build [system, user] messages, call llm.nu, return prose.
# When the contract declares `action.corpus`, retrieval pre-step runs:
# embed the user prompt, open the corpus, take top-k chunks via
# `rag similarity`, inject them as a system message before the user turn.

plugin use rag

use ./llm.nu *

export def consult [contract: string, prompt: string] {
  let c = (open $contract)
  if $c.action.verb != "Consult" {
    error make { msg: $"engine: only 'Consult' verb is implemented; got '($c.action.verb)' in ($contract)" }
  }

  let context = (retrieve-context $c $prompt)

  let messages = if ($context | str length) > 0 {
    [
      { role: "system", content: $c.prompt.system }
      { role: "system", content: $"Relevant Nushell documentation:\n\n($context)" }
      { role: "user", content: $prompt }
    ]
  } else {
    [
      { role: "system", content: $c.prompt.system }
      { role: "user", content: $prompt }
    ]
  }

  call-llm $messages
}

# Returns concatenated chunk text for the top-k corpus matches against the
# prompt, or an empty string if the contract declares no corpus / the corpus
# file is missing.
def retrieve-context [contract: record, prompt: string] {
  let corpus_path = ($contract.action.corpus? | default "")
  if ($corpus_path | str length) == 0 {
    return ""
  }
  if not ($corpus_path | path exists) {
    print --stderr $"warning: corpus '($corpus_path)' declared but not found; skipping retrieval"
    return ""
  }

  let k = ($contract.action.retrieval_k? | default 5)

  let qv = ([{text: $prompt}] | rag embed --column text | get 0.embedding)
  let hits = (open $corpus_path | rag similarity --query $qv --k $k)

  $hits | get text | str join "\n\n---\n\n"
}
