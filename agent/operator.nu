# Operator contract adapter for nu-agent.
#
# Pattern A (tool-call whitelist): natural-language task + Nushell tool schema
# → JSON array of {name, arguments} tool-call records. The runtime
# (agent/runtime.nu) validates and dispatches the returned calls against
# TOOL_NAMES.
#
# Pattern B (raw Nushell command strings) is a planned future milestone,
# deferred until RAG is functional — see docs/STATUS.md. Until then this
# adapter preserves the current tool-call semantics on top of the thin client.
#
# Built on call-llm-raw from llm.nu because Operator needs to include a
# `tools` field in the request body for native tool-call support.

use ../llm.nu [call-llm-raw]
use ./json.nu [coerce-json]

const SYSTEM_PROMPT = "You are a Contextualized Nushell Workbench. Your job is to translate user intent into precise Nushell tool-calls that operate on structured data. You MUST NOT take autonomous actions: emit only the explicit sequence of tool calls required to satisfy the request. For developer edits, strongly prefer the propose->apply workflow: produce non-mutating previews (files suffixed with .try) and wait for explicit confirmation before producing apply commands. When emitting tool calls in Operator/Enrichment mode, output ONLY a valid JSON array. Each item MUST be an object with keys 'name' and 'arguments'. Do NOT emit prose, explanations, markdown, or code fences. If no tools are needed, output []. When producing Nushell edits, prefer in-Nu primitives (open --raw, lines/enumerate/upsert, str replace). If new capability is required, propose it as a Rust nu_plugin. Do NOT generate or propose code in languages other than Nushell (.nu) or Rust (.rs). Do NOT reveal chain-of-thought or internal reasoning: output only the final JSON array or structured content required by the task."

# Parse a raw model response (or user-provided JSON string) into a list of
# tool-call records. Raises a helpful error on failure.
export def parse-json-calls-safe [raw] {
  try {
    coerce-json $raw
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    error make { msg: $"nu-agent expected JSON array output from the model, but parsing failed: ($reason)" }
  }
}

def operator-repair-prompt [task: string, broken: string, reason: string] {
  $"Original request: ($task)\nThe previous assistant output was invalid JSON.\nOutput was: (($broken | into string))\nReason: ($reason)\nReturn only a valid JSON array. Fix the JSON and do not add any extra text."
}

# Dispatch one Operator request: build the tool-aware body and post through
# the thin client. Returns the raw content string.
def call-raw-with-tools [user_prompt: string, tools: list] {
  let body = {
    messages: [
      { role: "system", content: $SYSTEM_PROMPT }
      { role: "user", content: $user_prompt }
    ]
    tools: $tools
  }
  (call-llm-raw $body)
}

# Operator entrypoint: given a task and a Nushell tool schema, return a
# parsed JSON array of tool calls. One repair retry on parse failure.
export def call-operator [task: string, tools: list] {
  let raw = (call-raw-with-tools $task $tools)

  try {
    (coerce-json $raw)
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    let repair_prompt = (operator-repair-prompt $task $raw $reason)
    let raw2 = (call-raw-with-tools $repair_prompt $tools)
    try {
      (coerce-json $raw2)
    } catch {
      error make { msg: "Operator did not return parseable JSON array after retry" }
    }
  }
}
