export def system-prompt [] {
  "You are a Nushell expert and a Nushell-only controller/developer for nu-agent. You may orchestrate only provided Nushell tools. If the user asks for multiple tool calls, you must emit every requested call in the exact order requested and must not stop after the first useful call. If the user asks for a specific tool sequence or exact tool count, preserve that order and count exactly. When making edits to files, strongly prefer the non-mutating propose-edit -> apply-edit flow over replace-in-file. When writing or modifying a Nushell script (.nu), strongly consider using the check-nu-syntax tool immediately afterward to verify your code. If the user asks for an edit preview, use the propose-edit tool call rather than skipping it. If new capability is needed, it must be proposed as a Rust nu_plugin exposed back as a Nushell command. You MUST NOT generate, write, or propose code in any languages other than Nushell (.nu) or Rust (.rs for nu_plugin). Do not write Python, Bash, JavaScript, etc. You MUST output ONLY a valid JSON array. Each item MUST be an object with keys 'name' and 'arguments'. Do NOT output prose, explanations, markdown, or code fences. If no tools are needed, output [].
  Do NOT reveal chain-of-thought, internal reasoning, or step-by-step deliberation. Never provide private thoughts or internal chain-of-thought; output only the final JSON array or structured content required by the task."
}

export def enrichment-system-prompt [] {
  "You are a Nushell expert helping enrich one structured record at a time. Return only valid JSON that matches the provided schema. Do not output prose, markdown, or code fences. Do not add extra keys. If a field is required, include it. If a field is marked non-null, do not set it to null.
  Do NOT reveal chain-of-thought, internal reasoning, or step-by-step deliberation. Output only the structured JSON required."
}

export def consultant-system-prompt [role: string] {
  let r = ($role | default "Consultant")
  let s = ("You are an expert " + $r + ". You will be given structured data (tables, records, JSON) produced by deterministic tools. Your job is to provide a natural-language interpretation, synthesis, and recommendations based only on the provided data and the user's query. Do NOT attempt to call any tools or modify files. Do NOT output JSON or tool-calls. Output clear, well-structured prose that answers the user's question and cites the provided data when appropriate. Do NOT reveal chain-of-thought or internal reasoning.")
  $s
}

def build-chat-body [system: string, prompt: string, tools: list] {
  let model = ($env.NU_AGENT_MODEL? | default "google/gemma-4-26b-a4b")

  {
    model: $model,
    temperature: 0,
    top_p: 1,
    messages: [
      { role: "system", content: $system }
      { role: "user", content: $prompt }
    ],
    tools: $tools
  }
}

def post-chat [body: string] {
  let chat_url = ($env.NU_AGENT_CHAT_URL? | default "http://172.19.224.1:1234/v1/chat/completions")
  let api_key = ($env.NU_AGENT_API_KEY? | default ($env.OPENAI_API_KEY? | default ""))

  # Some endpoints (eg. /v1/completions) expect a different request shape.
  let has_completions = ($chat_url | str contains "/v1/completions")
  let has_chat = ($chat_url | str contains "/v1/chat/completions")
  let is_completions = ($has_completions) and (not $has_chat)

  let res = if $is_completions {
    # Convert chat body to a simple completions-style body by concatenating
    # system and user messages into a single prompt string.
    let parsed = ($body | from json)
    let sys = (( $parsed | get messages) | get 0 | get content | default "")
    let user = (( $parsed | get messages) | get 1 | get content | default "")
    let prompt = if ($sys | str length) > 0 { $sys ++ "\n" ++ $user } else { $user }
    let comp_body = { model: ($parsed.model), prompt: $prompt, max_tokens: ($parsed.max_tokens? | default 1500), temperature: ($parsed.temperature? | default 0), top_p: ($parsed.top_p? | default 1) } | to json

    if ($api_key | str length) > 0 {
      try {
        http post -t application/json -H [ $"Authorization: Bearer ($api_key)" ] --max-time 120sec --full $chat_url $comp_body
      } catch { |err|
        error make { msg: ($"HTTP post failed and no shell fallback allowed: ({err.msg? | default (err | to text)})") }
      }
    } else {
      try {
        http post -t application/json --max-time 120sec --full $chat_url $comp_body
      } catch { |err|
        error make { msg: ($"HTTP post failed and no shell fallback allowed: ({err.msg? | default (err | to text)})") }
      }
    }
  } else {
    if ($api_key | str length) > 0 {
      try {
        http post -t application/json -H [ $"Authorization: Bearer ($api_key)" ] --max-time 120sec --full $chat_url $body
      } catch { |err|
        error make { msg: ($"HTTP post failed and no shell fallback allowed: ({err.msg? | default (err | to text)})") }
      }
    } else {
      try {
        http post -t application/json --max-time 120sec --full $chat_url $body
      } catch { |err|
        error make { msg: ($"HTTP post failed and no shell fallback allowed: ({err.msg? | default (err | to text)})") }
      }
    }
  }

  if $res.status >= 400 {
    error make { msg: $"API request failed with status ($res.status): ($res.body | to json)" }
  }

  # Normalize response shapes between chat-style responses
  # (choices[].message) and completion-style responses (choices[].text).
  let choice = $res.body.choices.0

  if ($choice.message? | default null) != null {
    # Chat-style responses: return only the content and metadata to avoid
    # exposing internal "reasoning" fields or chain-of-thought artifacts.
    let msg = $choice.message
    let content = (msg.content? | default "" | str trim)
    let meta = (msg.metadata? | default {})
    ({ content: $content, metadata: ($meta | merge { response_type: "chat" }) })
  } else if ($choice.text? | default "" | str trim | str length) > 0 {
    # Turn completion-style choice into an object compatible with
    # call-llm/call-llm-content expectations (provide .content) and
    # annotate it so callers can recognise it came from a completions
    # endpoint and potentially apply more aggressive cleaning.
    { content: ($choice.text | str trim), metadata: { response_type: "completion" } }
  } else {
    error make { msg: "API returned an unknown response shape (neither choices[].message nor choices[].text present)" }
  }
}

export def call-llm [prompt: string, tools: list] {
  # Backwards-compatible wrapper around call-llm-raw that returns only
  # the content string (existing callers expect a string).
  let raw = (call-llm-raw $prompt $tools)
  ($raw.content | default "")
}

def call-llm-raw [prompt: string, tools: list] {
  let system = (system-prompt)
  let body = ((build-chat-body $system $prompt $tools) | to json)
  let message = (post-chat $body)

  let content = if ($message.content? | default "" | str trim | str length) > 0 {
    ($message.content | str trim)
  } else if ($message.tool_calls? | default [] | length) > 0 {
    ($message.tool_calls | each { |tc|
      {
        name: $tc.function.name,
        arguments: ($tc.function.arguments | from json)
      }
    } | to json)
  } else {
    ""
  }

  let metadata = ($message.metadata? | default {})

  { content: $content, metadata: $metadata }
}

export def call-llm-content [prompt: string] {
  let system = (enrichment-system-prompt)
  let body = ((build-chat-body $system $prompt []) | to json)
  let message = (post-chat $body)

  if ($message.content? | default "" | str trim | str length) > 0 {
    ($message.content | str trim)
  } else {
    error make { msg: "LLM did not return content" }
  }
}
