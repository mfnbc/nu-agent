# Thin LLM client.
#
# Two exported functions:
#
#   call-llm-raw $body → string
#     The primitive. Merges model/temperature/reasoning defaults into the
#     supplied body, POSTs to the hardcoded endpoint, returns the content
#     string. Response normalisation handles chat-style (choices[].message),
#     completion-style (choices[].text), and native tool-call responses
#     (choices[].message.tool_calls — serialized into a JSON string so the
#     caller's parser sees a single content shape).
#
#   call-llm $messages → string
#     Convenience wrapper for the common case: caller supplies only a messages
#     list, everything else comes from defaults. Used by Enrichment and
#     Consultant adapters.
#
# Endpoint, model, timeout, temperature, reasoning suppression are hardcoded
# at this stage. Configurability returns when a concrete need surfaces.

const CHAT_URL = "http://172.19.224.1:1234/v1/chat/completions"
const MODEL = "google/gemma-4-26b-a4b"
const TIMEOUT = 2min

# Post a chat body to the LLM endpoint and return the content string.
# Callers may supply any subset of fields in $body (at minimum `messages`);
# default model/temperature/reasoning fields are merged in.
export def call-llm-raw [body: record] {
  let defaults = {
    model: $MODEL
    temperature: 0
    top_p: 1
    reasoning_format: "none"
    include_reasoning: false
  }
  let merged_body = ($defaults | merge $body)

  let headers = {
    "Content-Type": "application/json"
    Connection: "close"
    Accept: "application/json"
  }

  let http_out = (
    http post
      -t application/json
      --full
      -H $headers
      $CHAT_URL
      $merged_body
      --max-time $TIMEOUT
  )

  if $http_out.status >= 400 {
    let body_text = try { ($http_out.body | to json) } catch { $http_out.body }
    error make { msg: $"LLM request failed with status ($http_out.status): ($body_text)" }
  }

  let parsed_body = try { ($http_out.body | from json) } catch { $http_out.body }
  let choice = ($parsed_body.choices.0)

  # Normalize chat-style (choices[].message), native-tool-call
  # (choices[].message.tool_calls), and completion-style (choices[].text)
  # into a single content string for the caller.
  if ($choice.message? | default null) != null {
    let message = ($choice | get message)
    let raw = if (($message.content? | default "") | str length) > 0 {
      $message.content
    } else if (($message.tool_calls? | default [] | length) > 0) {
      # Serialize native tool_calls into the JSON-array-of-{name, arguments}
      # shape the Operator adapter already parses.
      ($message.tool_calls | each { |tc|
        { name: $tc.function.name, arguments: ($tc.function.arguments | from json) }
      } | to json)
    } else {
      # Final fallback: some endpoints leak reasoning_content even when
      # reasoning suppression is requested.
      ($message.reasoning_content? | default "")
    }
    let content = ($raw | str trim)
    if ($content | str length) == 0 {
      error make { msg: "LLM returned empty content: message.content, message.tool_calls, and message.reasoning_content were all missing or empty. Check reasoning suppression settings or model state." }
    }
    $content
  } else if (($choice.text? | default "") | str trim | str length) > 0 {
    ($choice.text | str trim)
  } else {
    error make { msg: "LLM returned an unknown response shape (neither choices[].message nor choices[].text)" }
  }
}

# Call the LLM with a list of chat messages. Thin wrapper over call-llm-raw
# for the common case with no extra body fields (no tools, no overrides).
export def call-llm [messages: list] {
  (call-llm-raw { messages: $messages })
}
