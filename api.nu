export def system-prompt [] {
  "You are a Nushell expert and a Nushell-only controller/developer for nu-agent. You may orchestrate only provided Nushell tools. If the user asks for multiple tool calls, you must emit every requested call in the exact order requested and must not stop after the first useful call. If the user asks for a specific tool sequence or exact tool count, preserve that order and count exactly. When making edits to files, strongly prefer the non-mutating propose-edit -> apply-edit flow over replace-in-file. When writing or modifying a Nushell script (.nu), strongly consider using the check-nu-syntax tool immediately afterward to verify your code. If the user asks for an edit preview, use the propose-edit tool call rather than skipping it. If new capability is needed, it must be proposed as a Rust nu_plugin exposed back as a Nushell command. You MUST NOT generate, write, or propose code in any languages other than Nushell (.nu) or Rust (.rs for nu_plugin). Do not write Python, Bash, JavaScript, etc. You MUST output ONLY a valid JSON array. Each item MUST be an object with keys 'name' and 'arguments'. Do NOT output prose, explanations, markdown, or code fences. If no tools are needed, output []."
}

export def enrichment-system-prompt [] {
  "You are a Nushell expert helping enrich one structured record at a time. Return only valid JSON that matches the provided schema. Do not output prose, markdown, or code fences. Do not add extra keys. If a field is required, include it. If a field is marked non-null, do not set it to null."
}

def build-chat-body [system: string, prompt: string, tools: list] {
  let model = ($env.NU_AGENT_MODEL? | default "gpt-4o")

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
  let chat_url = ($env.NU_AGENT_CHAT_URL? | default "https://api.openai.com/v1/chat/completions")
  let api_key = ($env.NU_AGENT_API_KEY? | default ($env.OPENAI_API_KEY? | default ""))

  let res = if ($api_key | str length) > 0 {
    http post -t application/json -H [ $"Authorization: Bearer ($api_key)" ] --max-time 120sec --full $chat_url $body
  } else {
    http post -t application/json --max-time 120sec --full $chat_url $body
  }

  if $res.status >= 400 {
    error make { msg: $"API request failed with status ($res.status): ($res.body | to json)" }
  }

  $res.body.choices.0.message
}

export def call-llm [prompt: string, tools: list] {
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

  if not ($content | str starts-with "[") {
    error make { msg: "LLM did not return JSON array" }
  }

  $content
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
