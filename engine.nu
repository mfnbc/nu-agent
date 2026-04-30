# Contract execution engine.
#
# Reads a contract TOML and dispatches by `action.verb`:
#
#   Consult     — single-shot. Engine pre-retrieves top-k chunks from the
#                 declared corpus, injects them as a system message, calls
#                 the LLM once, returns prose.
#
#   Investigate — multi-turn tool loop. Engine sends the system prompt + a
#                 tool array to the LLM, dispatches whatever tool calls
#                 come back, appends results as tool messages, repeats
#                 until the LLM emits a final answer or
#                 `action.max_iterations` is hit. See `build-tools-array`
#                 below for the catalog of supported tools.
#
# Plugin commands `rag embed` and `rag similarity` must be registered via
# `plugin add ./crates/nu_plugin_rag/target/debug/nu_plugin_rag` once
# before this engine is invoked.

use ./config.nu *
use ./llm.nu *

# Embed a single text string and return its embedding vector. Wraps `rag embed`
# with config-derived endpoint/model/batch-size so the engine never silently
# relies on plugin defaults.
def embed-one [text: string] {
  let emb = (get-config | get embedding)
  ([{text: $text}]
   | rag embed --column text --url $emb.url --model $emb.model --batch-size $emb.batch_size
   | get 0.embedding)
}

# Tool descriptors for the LLM's `tools` body field — OpenAI function-calling shape.
const SEARCH_NU_DOCS_TOOL = {
  type: "function"
  function: {
    name: "search_nu_docs"
    description: "Retrieve chunks from the Nushell documentation corpus by semantic similarity. Use this to verify a command, flag, or idiom rather than relying on memory."
    parameters: {
      type: "object"
      properties: {
        query: {
          type: "string"
          description: "Natural-language search query."
        }
        k: {
          type: "integer"
          description: "Number of top results to return (default 3)."
        }
      }
      required: ["query"]
    }
  }
}

const CHECK_NU_SYNTAX_TOOL = {
  type: "function"
  function: {
    name: "check_nu_syntax"
    description: "Parse-check a Nushell code snippet without executing it. Returns 'OK' if it parses cleanly, otherwise the parser's diagnostics verbatim. Call this before finalising any nu code in your answer."
    parameters: {
      type: "object"
      properties: {
        code: {
          type: "string"
          description: "Nushell code to parse-check (the contents of a single code block)."
        }
      }
      required: ["code"]
    }
  }
}

const FIND_FILES_TOOL = {
  type: "function"
  function: {
    name: "find_files"
    description: "Find files matching a glob pattern, scoped to the working directory tree the agent was invoked from. Use this to locate scripts, config files, or other artifacts the user is asking about. Returns matching paths joined by newlines."
    parameters: {
      type: "object"
      properties: {
        pattern: {
          type: "string"
          description: "Glob pattern relative to the working directory (e.g., '**/*.nu', 'crates/**/Cargo.toml'). Standard glob syntax."
        }
      }
      required: ["pattern"]
    }
  }
}

const READ_FILE_TOOL = {
  type: "function"
  function: {
    name: "read_file"
    description: "Read a file's contents, scoped to the working directory tree. Returns line-numbered text. Use this to inspect a specific file the user asked about, or one located via find_files."
    parameters: {
      type: "object"
      properties: {
        path: {
          type: "string"
          description: "Path to the file, relative to the working directory or absolute (must resolve under the working directory)."
        }
        offset: {
          type: "integer"
          description: "Line number to start from (1-indexed). Default 1."
        }
        limit: {
          type: "integer"
          description: "Maximum number of lines to return. Default 2000."
        }
      }
      required: ["path"]
    }
  }
}

export def run [contract: string, prompt: string] {
  let c = (open $contract)
  match $c.action.verb {
    "Consult" => (run-consult $c $prompt)
    "Investigate" => (run-investigate $c $prompt)
    _ => { error make { msg: $"engine: unsupported action verb '($c.action.verb)' in ($contract)" } }
  }
}

# Consult action: deterministic pre-retrieval (when corpus is declared) → single LLM call.
def run-consult [contract: record, prompt: string] {
  let context = (retrieve-context $contract $prompt)
  let messages = if ($context | str length) > 0 {
    [
      { role: "system", content: $contract.prompt.system }
      { role: "system", content: $"Relevant Nushell documentation:\n\n($context)" }
      { role: "user", content: $prompt }
    ]
  } else {
    [
      { role: "system", content: $contract.prompt.system }
      { role: "user", content: $prompt }
    ]
  }
  call-llm $messages
}

# Investigate action: tool-calling loop. The LLM decides when (and what) to retrieve.
def run-investigate [contract: record, prompt: string] {
  let max_iter = ($contract.action.max_iterations? | default 5)
  let tools_whitelist = ($contract.action.tools? | default [])
  let llm_tools = (build-tools-array $tools_whitelist)

  mut messages = [
    { role: "system", content: $contract.prompt.system }
    { role: "user", content: $prompt }
  ]

  mut iter = 0
  mut final_content = ""
  loop {
    if $iter >= $max_iter {
      error make { msg: $"engine: max_iterations ($max_iter) reached without final answer" }
    }

    let msg = (call-llm-message { messages: $messages, tools: $llm_tools })
    let tcs = ($msg.tool_calls? | default [])

    if ($tcs | length) == 0 {
      $final_content = ($msg.content? | default "")
      break
    }

    # Append the assistant's tool-call turn to the history.
    $messages = ($messages | append {
      role: "assistant"
      content: ($msg.content? | default "")
      tool_calls: $tcs
    })

    # Run each tool, append its result as a tool message.
    for tc in $tcs {
      let name = $tc.function.name
      let args = (try { ($tc.function.arguments | from json) } catch { {} })
      print --stderr $"engine: ($name) ($args | to json -r)"
      let result = (try {
        dispatch-tool $name $args $contract $tools_whitelist
      } catch { |e|
        $"tool error: (try { $e.msg } catch { $e | to text })"
      })
      $messages = ($messages | append {
        role: "tool"
        tool_call_id: $tc.id
        content: $result
      })
    }

    $iter = ($iter + 1)
  }

  $final_content
}

# Build the `tools` array for the LLM body from a whitelist of tool names.
def build-tools-array [whitelist: list] {
  $whitelist | each { |t|
    match $t {
      "search_nu_docs" => $SEARCH_NU_DOCS_TOOL
      "check_nu_syntax" => $CHECK_NU_SYNTAX_TOOL
      "find_files" => $FIND_FILES_TOOL
      "read_file" => $READ_FILE_TOOL
      _ => null
    }
  } | where $it != null
}

# Dispatch a single tool call. Rejects names not in the contract's whitelist.
def dispatch-tool [name: string, args: record, contract: record, whitelist: list] {
  if ($name not-in $whitelist) {
    return $"tool error: '($name)' not in this contract's tool whitelist"
  }
  match $name {
    "search_nu_docs" => (tool-search-nu-docs $args $contract)
    "check_nu_syntax" => (tool-check-nu-syntax $args)
    "find_files" => (tool-find-files $args)
    "read_file" => (tool-read-file $args)
    _ => $"tool error: no implementation for '($name)'"
  }
}

# search_nu_docs implementation: embed query → similarity over corpus → top-k chunks as text.
def tool-search-nu-docs [args: record, contract: record] {
  let q = ($args.query? | default "")
  if ($q | str length) == 0 {
    return "tool error: search_nu_docs requires a non-empty `query` argument"
  }
  let k = ($args.k? | default 3)
  let corpus_path = ($contract.action.corpus? | default "")
  if ($corpus_path | str length) == 0 {
    return "tool error: contract declares no `action.corpus`"
  }
  if not ($corpus_path | path exists) {
    return $"tool error: corpus '($corpus_path)' not found on disk"
  }

  let qv = (embed-one $q)
  let hits = (open $corpus_path | rag similarity --query $qv --k $k)
  $hits | each { |h|
    $"Source: ($h.source)\nTitle: ($h.title)\nScore: ($h.score)\n\n($h.text)"
  } | str join "\n\n---\n\n"
}

# check_nu_syntax implementation: write the code to a temp file, run `nu --ide-check`,
# return the parser's stdout/stderr verbatim (or "OK" when it's silent).
def tool-check-nu-syntax [args: record] {
  let code = ($args.code? | default "")
  if ($code | str length) == 0 {
    return "tool error: check_nu_syntax requires a non-empty `code` argument"
  }
  let tmpfile = $"/tmp/nu-agent-check-(random uuid).nu"
  $code | save --raw $tmpfile
  let result = (do { ^nu --ide-check 5 $tmpfile } | complete)
  rm -f $tmpfile
  let stdout = ($result.stdout | str trim)
  let stderr = ($result.stderr | str trim)
  if ($stdout | str length) == 0 and ($stderr | str length) == 0 and $result.exit_code == 0 {
    "OK"
  } else if ($stdout | str length) > 0 and ($stderr | str length) > 0 {
    $"stdout:\n($stdout)\n\nstderr:\n($stderr)"
  } else if ($stdout | str length) > 0 {
    $stdout
  } else if ($stderr | str length) > 0 {
    $stderr
  } else {
    $"nu --ide-check exited with code ($result.exit_code) and no diagnostic output"
  }
}

# Lexical containment check: returns true if `p` (after expansion) lives at or
# below the working directory. Both paths run through `path expand` so that
# `..` and `~` are collapsed before comparison; if `path expand` resolves
# symlinks, a symlink escaping cwd will fail this check (intentional).
def is-under-cwd [p: string] {
  let cwd_abs = (pwd | path expand)
  let p_abs = ($p | path expand)
  if $p_abs == $cwd_abs { return true }
  ($p_abs | str starts-with ($cwd_abs + "/"))
}

# find_files implementation: glob within cwd; reject any matches that escape.
# Caps at 500 results with a truncation tail to keep tool output bounded.
def tool-find-files [args: record] {
  let pat = ($args.pattern? | default "")
  if ($pat | str length) == 0 {
    return "tool error: find_files requires a non-empty `pattern` argument"
  }
  let raw = (try { glob $pat } catch { null })
  if $raw == null {
    return $"tool error: glob failed for pattern '($pat)'"
  }
  let in_scope = ($raw | where { |p| is-under-cwd $p })
  let count = ($in_scope | length)
  if $count == 0 {
    return "(no matches)"
  }
  if $count > 500 {
    let body = ($in_scope | first 500 | str join "\n")
    let extra = ($count - 500)
    $"($body)\n\n... ($extra) more matches truncated; refine your pattern"
  } else {
    $in_scope | str join "\n"
  }
}

# read_file implementation: cwd-scoped, line-numbered, default 2000-line cap.
# Output format: a header line ("# path — lines A–B of N") followed by tab-
# separated `<lineno>\t<content>` rows, matching the shape Claude Code's Read
# tool emits — familiar to any LLM trained against that conversation style.
def tool-read-file [args: record] {
  let raw_path = ($args.path? | default "")
  if ($raw_path | str length) == 0 {
    return "tool error: read_file requires a non-empty `path` argument"
  }
  if not (is-under-cwd $raw_path) {
    return $"tool error: path '($raw_path)' resolves outside the working directory"
  }
  let abs = ($raw_path | path expand)
  if not ($abs | path exists) {
    return $"tool error: file '($raw_path)' not found"
  }
  let info = (try { ls $abs | get 0 } catch { null })
  if $info == null {
    return $"tool error: could not stat '($raw_path)'"
  }
  let kind = ($info.type)
  if $kind != "file" {
    return $"tool error: '($raw_path)' is not a regular file. type: ($kind)"
  }
  let text = (try { open --raw $abs | decode utf-8 } catch { null })
  if $text == null {
    return $"tool error: '($raw_path)' is not valid UTF-8 text"
  }
  let all_lines = ($text | lines)
  let total = ($all_lines | length)
  let offset = ($args.offset? | default 1)
  let limit = ($args.limit? | default 2000)
  let start_idx = (if $offset > 0 { $offset - 1 } else { 0 })
  let slice = ($all_lines | skip $start_idx | take $limit)
  let returned = ($slice | length)
  if $returned == 0 {
    return $"# ($raw_path) — empty range (offset ($offset), file has ($total) lines)"
  }
  let numbered = ($slice | enumerate | each { |row|
    let n = ($start_idx + $row.index + 1)
    $"($n)\t($row.item)"
  } | str join "\n")
  let last = ($start_idx + $returned)
  $"# ($raw_path) — lines ($start_idx + 1)–($last) of ($total)\n($numbered)"
}

# Consult retrieval pre-step. Returns concatenated chunk text for the top-k corpus matches,
# or empty string when no corpus is declared / corpus file is missing.
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
  let qv = (embed-one $prompt)
  let hits = (open $corpus_path | rag similarity --query $qv --k $k)
  $hits | get text | str join "\n\n---\n\n"
}
