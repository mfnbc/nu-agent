# Thin LLM client.
#
# Two exported functions:
#
#   call-llm-raw $body → string
#     The primitive. Merges model/temperature/reasoning defaults into the
#     supplied body, POSTs to the configured chat endpoint, returns the
#     content string. Response normalisation handles chat-style
#     (choices[].message), completion-style (choices[].text), and native
#     tool-call responses (choices[].message.tool_calls — serialized into a
#     JSON string so the caller's parser sees a single content shape).
#
#   call-llm $messages → string
#     Convenience wrapper: caller supplies only a messages list.
#
#   call-llm-message $body → record
#     Like call-llm-raw, but returns the full choice.message record
#     (content + tool_calls + role) instead of collapsing to content.
#     Used by the Investigate action where the engine needs to decide
#     whether the response is a tool call or a final answer.
#
# Endpoint, model, and timeout come from `config.nu`'s cascade. Override
# locally via ./config.local.toml, ~/.config/nu-agent/config.toml, or
# NU_AGENT_CHAT_URL / NU_AGENT_CHAT_MODEL env vars.

use ./config.nu *

const HEADERS = {
  "Content-Type": "application/json"
  Connection: "close"
  Accept: "application/json"
}

# Build the merged body record (defaults + user fields) for one chat call.
def build-body [body: record, model: string] {
  let defaults = {
    model: $model
    temperature: 0
    top_p: 1
    reasoning_format: "none"
    include_reasoning: false
  }
  ($defaults | merge $body)
}

# Generic POST to an LLM endpoint (chat or embeddings).
# Parses the JSON response or throws an error.
def post-llm [url: string, body: record, timeout: duration] {
  let http_out = (
    http post
      -t application/json
      --full
      -H $HEADERS
      $url
      $body
      --max-time $timeout
  )

  if $http_out.status >= 400 {
    let body_text = try { ($http_out.body | to json) } catch { $http_out.body }
    error make { msg: $"LLM request failed with status ($http_out.status): ($body_text)" }
  }

  try { ($http_out.body | from json) } catch { $http_out.body }
}

def post-chat-with-config [body: record] {
  let chat = (get-config | get chat)
  let timeout = (try { $chat.timeout | into duration } catch { 2min })
  let merged_body = (build-body $body $chat.model)
  post-llm $chat.url $merged_body $timeout
}

# Post a chat body to the LLM endpoint and return the content string.
export def call-llm-raw [body: record] {
  let parsed_body = (post-chat-with-config $body)
  let choice = ($parsed_body.choices.0)

  # Normalize chat-style (choices[].message), native-tool-call
  # (choices[].message.tool_calls), and completion-style (choices[].text)
  # into a single content string for the caller.
  if ($choice.message? | default null) != null {
    let message = ($choice | get message)
    let raw = if ($message.content? | default "") != "" {
      $message.content
    } else if (($message.tool_calls? | default [] | length) > 0) {
      # Serialize native tool_calls into a JSON-array-of-{name, arguments}.
      ($message.tool_calls | each { |tc|
        { name: $tc.function.name, arguments: ($tc.function.arguments | from json) }
      } | to json)
    } else {
      # Final fallback: some endpoints leak reasoning_content even when
      # reasoning suppression is requested.
      ($message.reasoning_content? | default "")
    }
    let content = ($raw | str trim)
    if $content == "" {
      error make { msg: "LLM returned empty content: message.content, message.tool_calls, and message.reasoning_content were all missing or empty. Check reasoning suppression settings or model state." }
    }
    $content
  } else if (($choice.text? | default "") | str trim) != "" {
    ($choice.text | str trim)
  } else {
    error make { msg: "LLM returned an unknown response shape (neither choices[].message nor choices[].text)" }
  }
}

export def call-llm [messages: list] {
  (call-llm-raw { messages: $messages })
}

export def call-llm-message [body: record] {
  let parsed_body = (post-chat-with-config $body)
  ($parsed_body.choices.0.message)
}

# --- Embeddings ---

# Call the configured embedding endpoint with a list of strings.
# Returns a list of embedding vectors (list<list<float>>).
export def call-llm-embed [texts: list<string>] {
  let cfg = (get-config | get embedding)
  let timeout = (try { $cfg.timeout | into duration } catch { 5min })
  let body = { model: $cfg.model, input: $texts }
  
  print $"[llm.nu] Sending batch of ($texts | length) to ($cfg.url) (model: ($cfg.model))"
  let response = (post-llm $cfg.url $body $timeout)
  print $"[llm.nu] Received response from ($cfg.url)"
  
  # Return the list of float arrays
  $response.data | get embedding
}

# Pipeline filter: chunk records, fetch embeddings, zip vectors into the 'embedding' column.
export def attach-embeddings [
  --batch-size: int
  --column: string = "embedding_input"
] {
  let stream = $in
  
  let cfg = (get-config | get embedding)
  let active_batch_size = ($batch_size | default ($cfg.batch_size? | default 16))

  $stream | chunks $active_batch_size | each { |batch|
    let texts = ($batch | get $column)
    let embeddings = (call-llm-embed $texts)
    
    $batch | zip $embeddings | each { |pair|
      $pair.0 | insert embedding $pair.1
    }
  } | flatten
}
