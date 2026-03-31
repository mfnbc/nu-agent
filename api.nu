export def system-prompt [] {
  "You are a Nushell expert and a Nushell-only controller/developer for nu-agent. You may orchestrate only provided Nushell tools. If new capability is needed, it must be proposed as a Rust nu_plugin exposed back as a Nushell command. You MUST output ONLY a valid JSON array. Each item MUST be an object with keys 'name' and 'arguments'. Do NOT output prose, explanations, markdown, or code fences. If no tools are needed, output []."
}

export def call-llm [prompt: string, tools: list] {
  let system = (system-prompt)
  let model = ($env.NU_AGENT_MODEL? | default "gpt-5.3-chat-latest")
  let chat_url = ($env.NU_AGENT_CHAT_URL? | default "https://api.openai.com/v1/chat/completions")
  let api_key = ($env.NU_AGENT_API_KEY? | default ($env.OPENAI_API_KEY? | default ""))

  let body = {
    model: $model,
    temperature: 0,
    top_p: 1,
    messages: [
      { role: "system", content: $system },
      { role: "user", content: $prompt }
    ],
    tools: $tools
  }

  let res = if ($api_key | str length) > 0 {
    http post -H [ $"Authorization: Bearer ($api_key)" ] $chat_url $body
  } else {
    http post $chat_url $body
  }

  let content = ($res.choices.0.message.content | str trim)

  if not ($content | str starts-with "[") {
    error make { msg: "LLM did not return JSON array" }
  }

  $content
}
