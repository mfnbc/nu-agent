# LLM interaction helpers for nu-agent

use ../api.nu *
use ./json.nu [coerce-json]

export def parse-json-calls-safe [raw] {
  try {
    coerce-json $raw
  } catch { |err|
    let reason = ($err.msg? | default ($err | to text))
    error make { msg: $"nu-agent expected JSON array output from the model, but parsing failed: ($reason)" }
  }
}

def repair-prompt [task: string, broken: string, reason: string] {
  $"Original request: ($task)\nThe previous assistant output was invalid JSON.\nOutput was: (($broken | into string))\nReason: ($reason)\nReturn only a valid JSON array. Fix the JSON and do not add any extra text."
}

export def call-llm-json [task: string, tools: list] {
  # Use raw call to obtain metadata about the response type.
  let raw_obj = (call-llm-raw $task $tools)
  let raw = ($raw_obj.content | default "")
  let resp_type = ($raw_obj.metadata.response_type? | default "chat")

  # If the response came from a completion endpoint, aggressively try to
  # extract a JSON array even when the model emits extra text.
  if $resp_type == "completion" {
    if not ($raw | str starts-with "[") {
      # Attempt to extract the first JSON array substring from the text.
      try {
        # Use index-of for compatibility with Nushell 0.111.0 and later
        let start = ($raw | str index-of "[")
        let end = ($raw | str index-of -e "]")
        if ($start >= 0) and ($end >= $start) {
          # substring expects start and length; include the closing bracket
          let candidate = ($raw | str substring $start (($end - $start) + 1))
          let parsed = (coerce-json $candidate)
          parsed
        } else {
          # fallthrough to normal repair flow
          throw make { msg: "no bracketed array found" }
        }
      } catch { |e|
        # Fallback: perform the repair prompt flow
        let reason = ($e.msg? | default ($e | to text))
        let retry_task = (repair-prompt $task $raw $reason)
        let raw2 = (call-llm $retry_task $tools)

        try {
          coerce-json $raw2
        } catch {
          error make { msg: "LLM did not return parseable JSON array after retry" }
        }
      }
    } else {
      try { coerce-json $raw } catch { |err|
        let reason = ($err.msg? | default ($err | to text))
        let retry_task = (repair-prompt $task $raw $reason)
        let raw2 = (call-llm $retry_task $tools)

        try { coerce-json $raw2 } catch { error make { msg: "LLM did not return parseable JSON array after retry" } }
      }
    }
  } else {
    # Default chat-style behavior: expect clean JSON
    try { coerce-json $raw } catch { |err|
      let reason = ($err.msg? | default ($err | to text))
      let retry_task = (repair-prompt $task $raw $reason)
      let raw2 = (call-llm $retry_task $tools)

      try { coerce-json $raw2 } catch { error make { msg: "LLM did not return parseable JSON array after retry" } }
    }
  }
}

export def call-llm-consultant [role: string, prompt: string] {
  # Consultant mode: use the consultant system prompt and return prose
  let system = (consultant-system-prompt $role)
  let body = ((build-chat-body $system $prompt []) | to json)
  let message = (post-chat $body)

  if ($message.content? | default "" | str trim | str length) > 0 {
    ($message.content | str trim)
  } else {
    error make { msg: "LLM consultant did not return content" }
  }
}
