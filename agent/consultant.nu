# Consultant contract adapter for nu-agent.
#
# Role × prompt → prose synthesis. Takes a role name (e.g. "Nutritionist",
# "Chess-Coach", "Ledger-Auditor") and a user prompt that typically contains
# deterministic output from a prior Operator invocation, and returns prose
# interpretation. No tools, no JSON shape, no retry loop — a Consultant
# invocation is strictly read-only synthesis over the supplied context.
#
# Wings that want a specialised consultant (e.g. Nutritionist scoped to food
# + workout streams) should wrap `consult` with a fixed --role and whatever
# corpus assembly they need — the core adapter does not know about corpora.

use ../llm.nu *

# Compose the Consultant system prompt for a given role. The text is kept
# here rather than in api.nu so the adapter is self-contained.
def consultant-system-prompt [role: string] {
  let r = (if (($role | str length) == 0) { "Consultant" } else { $role })
  $"You are an expert ($r). You will be given structured data \(tables, records, JSON\) produced by deterministic tools. Your job is to provide a natural-language interpretation, synthesis, and recommendations based only on the provided data and the user's query. Do NOT attempt to call any tools or modify files. Do NOT output JSON or tool-calls. Output clear, well-structured prose that answers the user's question and cites the provided data when appropriate. Do NOT reveal chain-of-thought or internal reasoning."
}

def call-consultant [role: string, user_prompt: string] {
  let messages = [
    { role: "system", content: (consultant-system-prompt $role) }
    { role: "user", content: $user_prompt }
  ]
  let raw = (call-llm $messages)
  if (($raw | str length) == 0) {
    error make { msg: "Consultant returned empty response" }
  }
  $raw
}

# Public entrypoint. `--role` defaults to "Consultant"; wings override with
# their domain role ("Nutritionist", "Chess-Coach", etc.).
export def consult [--role: string = "Consultant", --prompt: string] {
  if (($prompt | default "" | str length) == 0) {
    error make { msg: "Missing required --prompt argument" }
  }
  (call-consultant $role $prompt)
}
