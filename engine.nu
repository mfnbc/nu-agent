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

# Engine module's own directory — used to locate the bundled `contracts/`
# fallback when a user-supplied contract path is missing on disk. Mirrors
# the pattern in config.nu.
const HERE = (path self | path dirname)

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
const TOOL_DEFS = {
  search_nu_docs: {
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
  check_nu_syntax: {
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
  find_files: {
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
  read_file: {
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
  propose_edit: {
    type: "function"
    function: {
      name: "propose_edit"
      description: "Propose a surgical edit to an existing file by replacing one occurrence of `old_string` with `new_string`. Verifies that `old_string` matches exactly once in the file (rejects otherwise). Does NOT write to disk — proposals are echoed to stderr and returned to you so you can summarize them in your final answer; the user reviews and applies them manually."
      parameters: {
        type: "object"
        properties: {
          path: {
            type: "string"
            description: "Path to an existing file, scoped to the working directory."
          }
          old_string: {
            type: "string"
            description: "Exact text to replace. Must match exactly once. Include surrounding context if the change point would otherwise be ambiguous."
          }
          new_string: {
            type: "string"
            description: "Replacement text."
          }
          rationale: {
            type: "string"
            description: "One-sentence justification for this edit."
          }
        }
        required: ["path", "old_string", "new_string", "rationale"]
      }
    }
  }
  propose_write: {
    type: "function"
    function: {
      name: "propose_write"
      description: "Propose creating a new file with the given content. Rejects if the file already exists (use propose_edit instead). Does NOT write to disk — proposals are echoed to stderr and returned to you so you can summarize them in your final answer; the user reviews and applies them manually."
      parameters: {
        type: "object"
        properties: {
          path: {
            type: "string"
            description: "Path for the new file, scoped to the working directory."
          }
          content: {
            type: "string"
            description: "Full contents of the new file."
          }
          rationale: {
            type: "string"
            description: "One-sentence justification for this new file."
          }
        }
        required: ["path", "content", "rationale"]
      }
    }
  }
}

# Tools that mutate the user's project (or propose to). Only contracts whose
# action.verb is "Enact" may dispatch these. Investigate contracts have these
# stripped from their tool array AND rejected at dispatch as a backstop.
const WRITE_TOOLS = ["propose_edit", "propose_write"]

# Resolve `p` to an existing contract file. If `p` is a file, return it
# as-is. If `p` is a directory, prefer `architect.toml` or the first
# `*.toml` found inside. Returns null if `p` doesn't exist or contains no
# .toml file.
def resolve-contract-at [p: string] {
  let kind = ($p | path type)
  if $kind == "file" { return $p }
  if $kind != "dir" { return null }
  let preferred = ($p | path join "architect.toml")
  if ($preferred | path type) == "file" { return $preferred }
  let found = (try { glob ($p | path join "*.toml") } catch { [] })
  if ($found | length) > 0 { $found | get 0 } else { null }
}

# Resolve a contract argument, with cascade fallback to the bundled repo
# contracts dir. Mirrors config.toml's cascade: if the user's override
# (e.g. `~/.config/nu-agent/contracts/architect.toml`) is missing, fall
# back to the committed `<repo>/contracts/<basename>`.
def resolve-contract-path [contract: string] {
  let direct = (resolve-contract-at $contract)
  if $direct != null { return $direct }

  let basename = if ($contract | str ends-with "/") {
    "architect.toml"
  } else {
    $contract | path basename
  }
  let bundled_dir = ($HERE | path join "contracts")
  let fallback = (resolve-contract-at ($bundled_dir | path join $basename))
  if $fallback != null {
    print --stderr $"engine: '($contract)' not found, using bundled '($fallback)'"
    return $fallback
  }
  error make { msg: $"engine: contract not found at '($contract)' or bundled '($bundled_dir)/($basename)'" }
}

export def run [contract: string, prompt: string] {
  let contract_path = (resolve-contract-path $contract)
  let c = (open $contract_path)
  match $c.action.verb {
    "Consult" => (run-consult $c $prompt)
    "Investigate" => (run-investigate $c $prompt)
    "Enact" => (run-investigate $c $prompt)
    _ => { error make { msg: $"engine: unsupported action verb '($c.action.verb)' in ($contract_path)" } }
  }
}

# Consult action: deterministic pre-retrieval (when corpus is declared) → single LLM call.
def run-consult [contract: record, prompt: string] {
  let context = (retrieve-context $contract $prompt)
  let messages = if $context != "" {
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
# Tracks propose-tool successes so that, if the loop exhausts max_iterations
# without a final answer but at least one proposal succeeded, the engine
# returns a graceful summary listing the .proposed files instead of erroring.
def run-investigate [contract: record, prompt: string] {
  let max_iter = ($contract.action.max_iterations? | default 5)
  let tools_whitelist = ($contract.action.tools? | default [])
  let verb = ($contract.action.verb? | default "")
  let llm_tools = (build-tools-array $tools_whitelist $verb)

  mut messages = [
    { role: "system", content: $contract.prompt.system }
    { role: "user", content: $prompt }
  ]

  mut iter = 0
  mut final_content = ""
  mut propose_count = 0
  mut proposed_paths = []
  loop {
    if $iter >= $max_iter {
      if $propose_count > 0 {
        let unique_paths = ($proposed_paths | uniq)
        let listing = ($unique_paths | each { |p| $"  - ($p).proposed" } | str join "\n")
        print --stderr $"engine: max_iterations ($max_iter) reached but ($propose_count) proposal\(s) succeeded; returning graceful summary"
        $final_content = $"Reached max_iterations \(($max_iter)\) without a clean final answer from the model, but ($propose_count) proposal\(s) were recorded. Review:\n($listing)\n\nOpen each .proposed file in your editor to review; `mv <path>.proposed <path>` to accept, `rm <path>.proposed` to reject."
        break
      }
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

      # Track propose successes for the graceful-end-of-loop summary. Both
      # fresh proposals and "already applied" retries reference a .proposed
      # path worth listing; only fresh ones increment the count.
      if ($name in $WRITE_TOOLS) {
        let p = ($args.path? | default "")
        if $p != "" and ($result | str starts-with "(proposal recorded)") {
          $propose_count = ($propose_count + 1)
          $proposed_paths = ($proposed_paths | append $p)
        } else if $p != "" and ($result | str starts-with "(already applied)") {
          $proposed_paths = ($proposed_paths | append $p)
        }
      }

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
# Strips write tools (propose_edit, propose_write) when verb != "Enact" so the
# LLM never sees them in non-Enact contracts.
def build-tools-array [whitelist: list, verb: string] {
  let allowed = if $verb == "Enact" {
    $whitelist
  } else {
    $whitelist | where { |t| $t not-in $WRITE_TOOLS }
  }
  $allowed | each { |t| $TOOL_DEFS | get -o $t } | where $it != null
}

# Dispatch a single tool call. Rejects names not in the contract's whitelist.
# Also rejects write tools when contract.action.verb != "Enact" — backstop
# for build-tools-array's filtering.
def dispatch-tool [name: string, args: record, contract: record, whitelist: list] {
  if ($name not-in $whitelist) {
    return $"tool error: '($name)' not in this contract's tool whitelist"
  }
  let verb = ($contract.action.verb? | default "")
  if ($name in $WRITE_TOOLS) and $verb != "Enact" {
    return $"tool error: '($name)' is a write tool; only Enact contracts may dispatch it"
  }
  match $name {
    "search_nu_docs" => (tool-search-nu-docs $args $contract)
    "check_nu_syntax" => (tool-check-nu-syntax $args)
    "find_files" => (tool-find-files $args)
    "read_file" => (tool-read-file $args)
    "propose_edit" => (tool-propose-edit $args)
    "propose_write" => (tool-propose-write $args)
    _ => $"tool error: no implementation for '($name)'"
  }
}

# search_nu_docs implementation: embed query → similarity over corpus → top-k chunks as text.
def tool-search-nu-docs [args: record, contract: record] {
  let q = ($args.query? | default "")
  if $q == "" {
    return "tool error: search_nu_docs requires a non-empty `query` argument"
  }
  let k = ($args.k? | default 3)
  let corpus_path = ($contract.action.corpus? | default "")
  if $corpus_path == "" {
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
  if $code == "" {
    return "tool error: check_nu_syntax requires a non-empty `code` argument"
  }
  let tmpfile = $"/tmp/nu-agent-check-(random uuid).nu"
  $code | save --raw $tmpfile
  let result = (do { ^nu --ide-check 5 $tmpfile } | complete)
  rm -f $tmpfile
  let stdout = ($result.stdout | str trim)
  let stderr = ($result.stderr | str trim)
  if $stdout == "" and $stderr == "" and $result.exit_code == 0 {
    "OK"
  } else if $stdout != "" and $stderr != "" {
    $"stdout:\n($stdout)\n\nstderr:\n($stderr)"
  } else if $stdout != "" {
    $stdout
  } else if $stderr != "" {
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
  $p_abs == $cwd_abs or ($p_abs | str starts-with ($cwd_abs + "/"))
}

# find_files implementation: glob within cwd; reject any matches that escape.
# Caps at 100 results with a truncation tail to keep tool output bounded.
# (Lower than you might expect — broad globs over a project with a data
# dir blow the LLM's per-turn ingestion budget on small local models.)
def tool-find-files [args: record] {
  let pat = ($args.pattern? | default "")
  if $pat == "" {
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
  if $count > 100 {
    let body = ($in_scope | first 100 | str join "\n")
    let extra = ($count - 100)
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
  if $raw_path == "" {
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

# propose_edit implementation: verify the file exists, the old_string matches
# exactly once, write the post-edit content to a `<path>.proposed` companion
# file (the original is NOT touched), and emit a structured preview. Multiple
# edits to the same path stack — the second edit reads from .proposed if
# present, building cumulatively on the first.
def tool-propose-edit [args: record] {
  let raw_path = ($args.path? | default "")
  if $raw_path == "" {
    return "tool error: propose_edit requires a non-empty `path` argument"
  }
  let old_string = ($args.old_string? | default "")
  if $old_string == "" {
    return "tool error: propose_edit requires a non-empty `old_string` argument"
  }
  let new_string = ($args.new_string? | default "")
  let rationale = ($args.rationale? | default "")
  if $rationale == "" {
    return "tool error: propose_edit requires a `rationale` argument (one-sentence justification)"
  }
  if not (is-under-cwd $raw_path) {
    return $"tool error: path '($raw_path)' resolves outside the working directory"
  }
  let abs = ($raw_path | path expand)
  if not ($abs | path exists) {
    return $"tool error: file '($raw_path)' not found — for new files, call propose_write instead"
  }

  # Cumulative source: if a .proposed companion already exists from an
  # earlier edit this session, build on top of it; otherwise start from
  # the original. This lets multiple edits to the same file stack.
  let proposed_path = ($abs + ".proposed")
  let source_path = if ($proposed_path | path exists) { $proposed_path } else { $abs }
  let source_label = if ($proposed_path | path exists) { $"($raw_path).proposed" } else { $raw_path }

  let text = (try { open --raw $source_path | decode utf-8 } catch { null })
  if $text == null {
    return $"tool error: '($source_label)' is not valid UTF-8 text"
  }
  let occurrences = (($text | split row $old_string | length) - 1)
  if $occurrences == 0 {
    # Idempotency: if old_string is missing but new_string is already
    # present in the source (which is .proposed when it exists), this
    # is almost certainly a retry of an already-applied edit. Return a
    # success-shaped result so the model breaks out of the retry loop.
    let new_count = if $new_string != "" {
      (($text | split row $new_string | length) - 1)
    } else {
      0
    }
    if $new_count >= 1 {
      let already = $"\(already applied\) ($raw_path) → ($raw_path).proposed already contains this change. Do NOT call propose_edit on this old_string again. Next action: write the final answer."
      print --stderr $already
      return $already
    }
    return $"tool error: old_string not found in '($source_label)' — verify exact text including whitespace"
  }
  if $occurrences > 1 {
    return $"tool error: old_string matches ($occurrences) times in '($source_label)' — add surrounding context to make the match unique"
  }

  let new_text = ($text | str replace $old_string $new_string)
  $new_text | save --raw --force $proposed_path

  # Verbose preview to stderr (for the user reading the trace); compact
  # directive return to the LLM (so it doesn't try to re-process the diff).
  let preview = $"# proposed edit to ($raw_path)\n# rationale: ($rationale)\n# preview written to ($raw_path).proposed\n--- old\n($old_string)\n--- new\n($new_string)\n---"
  print --stderr $preview
  $"\(proposal recorded\) ($raw_path) → ($raw_path).proposed; this change is complete. Do NOT call propose_edit on this old_string again. Next action: write the final answer.\n  rationale: ($rationale)"
}

# propose_write implementation: verify the file does NOT exist, write the
# proposed content to a `<path>.proposed` companion file (the path itself
# is NOT created), and emit a preview. Repeated propose_write to the same
# path overwrites the previous .proposed (last write wins).
def tool-propose-write [args: record] {
  let raw_path = ($args.path? | default "")
  if $raw_path == "" {
    return "tool error: propose_write requires a non-empty `path` argument"
  }
  let content = ($args.content? | default "")
  let rationale = ($args.rationale? | default "")
  if $rationale == "" {
    return "tool error: propose_write requires a `rationale` argument (one-sentence justification)"
  }
  if not (is-under-cwd $raw_path) {
    return $"tool error: path '($raw_path)' resolves outside the working directory"
  }
  let abs = ($raw_path | path expand)
  if ($abs | path exists) {
    return $"tool error: file '($raw_path)' already exists — to modify, call propose_edit instead"
  }

  let proposed_path = ($abs + ".proposed")
  $content | save --raw --force $proposed_path

  # Verbose preview to stderr (for the user reading the trace); compact
  # directive return to the LLM.
  let preview = $"# proposed new file: ($raw_path)\n# rationale: ($rationale)\n# preview written to ($raw_path).proposed\n--- content\n($content)\n---"
  print --stderr $preview
  $"\(proposal recorded\) new file ($raw_path).proposed written. Do NOT call propose_write on this path again. Next action: write the final answer.\n  rationale: ($rationale)"
}

# Consult retrieval pre-step. Returns concatenated chunk text for the top-k corpus matches,
# or empty string when no corpus is declared / corpus file is missing.
def retrieve-context [contract: record, prompt: string] {
  let corpus_path = ($contract.action.corpus? | default "")
  if $corpus_path == "" {
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
