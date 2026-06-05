# Nu-agent engine — generic tools and prompt runner on top of ai.nu.
#
# export-env registers 7 generic tools into AI_TOOLS and seeds prompts from
# contracts/*.toml into AI_PROMPTS. Domain tools live in their packages:
#   chess  → nuchessdb/ai/mod.nu
#   hebrew → biblexicon_builder/ai/mod.nu
#
# Verbs supported by `run`:
#   Consult     — single-shot with optional RAG pre-retrieval
#   Investigate — tool loop (ai-send drives internally via AI_TOOLS)
#   Enact       — tool loop with write tools included
#
# Requires ai.nu loaded first (AI_STATE, AI_SESSION, ai-do, ai-send).
# Requires nu_plugin_rag registered for RAG and ANN tools.

use ./config.nu *
use ./llm.nu *
use ../ai.nu/ai/config.nu [ai-config-env-tools, ai-config-env-prompts]
use ../ai.nu/ai/function.nu [closure-run, closure-list]
use ../ai.nu/ai/base.nu [ai-send]
use ../ai.nu/ai/data.nu

const HERE = (path self | path dirname)

# Tools that require Enact verb — not presented to LLM for Investigate/Consult.
const WRITE_TOOLS = ["propose_edit", "propose_write"]

export-env {
    if ($env.AI_TOOLS? | is-empty) { $env.AI_TOOLS = {} }
    if ($env.AI_CONFIG? | is-empty) { $env.AI_CONFIG = { tool_calls: "grey" } }

    let nu_docs = ($HERE | path join "data" "nu_docs.msgpack")

    ai-config-env-tools "search_nu_docs" {
        schema: {
            description: "Retrieve chunks from the Nushell documentation corpus by semantic similarity. Use this to verify a command, flag, or idiom rather than relying on memory."
            parameters: {
                type: "object"
                properties: {
                    query: { type: "string", description: "Natural-language search query." }
                    k: { type: "integer", description: "Number of top results to return (default 3)." }
                }
                required: ["query"]
            }
        }
        context: { corpus: $nu_docs }
        handler: {|args, ctx|
            let q = ($args.query? | default "")
            if $q == "" { return "tool error: requires non-empty `query`" }
            let k = ($args.k? | default 3)
            let corpus = ($ctx.corpus? | default "")
            if $corpus == "" or not ($corpus | path exists) {
                return $"tool error: corpus not found at '($corpus)'"
            }
            let qv = (embed-one $q)
            let hits = (open $corpus | rag similarity --query $qv --k $k)
            $hits | each { |h|
                $"Source: ($h.source)\nTitle: ($h.title)\nScore: ($h.score)\n\n($h.text)"
            } | str join "\n\n---\n\n"
        }
    }

    ai-config-env-tools "check_nu_syntax" {
        schema: {
            description: "Parse-check a Nushell code snippet without executing it. Returns 'OK' if it parses cleanly, otherwise the parser's diagnostics verbatim. Call this before finalising any nu code in your answer."
            parameters: {
                type: "object"
                properties: {
                    code: { type: "string", description: "Nushell code to parse-check." }
                }
                required: ["code"]
            }
        }
        handler: {|args, _| tool-check-nu-syntax $args }
    }

    ai-config-env-tools "search_ann" {
        schema: {
            description: "Query a persisted ANN index (HNSW or exact) using a natural-language query or embedding vector. Returns top-k hits (id + score)."
            parameters: {
                type: "object"
                properties: {
                    index: { type: "string", description: "Path to ANN index basename." }
                    map: { type: "string", description: "Path to the index id map JSON file." }
                    query: { type: "string", description: "Natural-language query to embed (optional)." }
                    query_vec: { type: "array", items: { type: "number" }, description: "Embedding vector (optional)." }
                    k: { type: "integer", description: "Number of top results (default 5)." }
                    ef_search: { type: "integer", description: "HNSW ef_search (default 200)." }
                }
                required: ["index", "map"]
            }
        }
        handler: {|args, _|
            let index = ($args.index? | default "")
            let map   = ($args.map? | default "")
            if $index == "" or $map == "" { return "tool error: requires `index` and `map`" }
            let k  = ($args.k? | default 5)
            let ef = ($args.ef_search? | default 200)
            if ($args.query? | default "") != "" {
                let qv = (embed-one $args.query)
                let hits = (rag ann-query-hnsw --index $index --map $map --query $qv --k $k --ef-search $ef)
                if ($hits | is-empty) { return "(no hits)" }
                $hits | each { |h| $"id=($h.id) score=($h.score) index=($h.index)" } | str join "\n"
            } else if ($args.query_vec? | default []) != [] {
                let hits = (rag ann-query-hnsw --index $index --map $map --query $args.query_vec --k $k --ef-search $ef)
                if ($hits | is-empty) { return "(no hits)" }
                $hits | each { |h| $"id=($h.id) score=($h.score) index=($h.index)" } | str join "\n"
            } else {
                "tool error: requires `query` (string) or `query_vec` (list)"
            }
        }
    }

    ai-config-env-tools "find_files" {
        schema: {
            description: "Find files matching a glob pattern, scoped to the working directory. Returns matching paths joined by newlines."
            parameters: {
                type: "object"
                properties: {
                    pattern: { type: "string", description: "Glob pattern (e.g. '**/*.nu'). Standard glob syntax." }
                }
                required: ["pattern"]
            }
        }
        handler: {|args, _| tool-find-files $args }
    }

    ai-config-env-tools "read_file" {
        schema: {
            description: "Read a file's contents, scoped to the working directory. Returns line-numbered text."
            parameters: {
                type: "object"
                properties: {
                    path: { type: "string", description: "Path to the file, relative to cwd or absolute." }
                    offset: { type: "integer", description: "Line number to start from (1-indexed, default 1)." }
                    limit: { type: "integer", description: "Maximum lines to return (default 2000)." }
                }
                required: ["path"]
            }
        }
        handler: {|args, _| tool-read-file $args }
    }

    ai-config-env-tools "propose_edit" {
        schema: {
            description: "Propose a surgical edit to an existing file by replacing one exact occurrence of old_string with new_string. Does NOT write to disk — writes a .proposed companion file for user review."
            parameters: {
                type: "object"
                properties: {
                    path: { type: "string", description: "Path to an existing file, scoped to cwd." }
                    old_string: { type: "string", description: "Exact text to replace. Must match exactly once." }
                    new_string: { type: "string", description: "Replacement text." }
                    rationale: { type: "string", description: "One-sentence justification." }
                }
                required: ["path", "old_string", "new_string", "rationale"]
            }
        }
        handler: {|args, _| tool-propose-edit $args }
    }

    ai-config-env-tools "propose_write" {
        schema: {
            description: "Propose creating a new file with given content. Rejects if the file already exists. Does NOT write to disk — writes a .proposed companion file for user review."
            parameters: {
                type: "object"
                properties: {
                    path: { type: "string", description: "Path for the new file, scoped to cwd." }
                    content: { type: "string", description: "Full contents of the new file." }
                    rationale: { type: "string", description: "One-sentence justification." }
                }
                required: ["path", "content", "rationale"]
            }
        }
        handler: {|args, _| tool-propose-write $args }
    }

    # Load contracts/*.toml into AI_PROMPTS so `run` can look them up by name.
    # Each contract contributes: system, template, placeholder, plus nu-agent
    # extensions (corpus, tools, verb) stored in the same record.
    let contracts_dir = ($HERE | path join "contracts")
    if ($contracts_dir | path exists) {
        glob ($contracts_dir | path join "*.toml")
        | each { |f|
            let c = (open $f)
            let name = ($f | path basename | str replace ".toml" "")
            ai-config-env-prompts $name {
                system:      $c.prompt.system
                template:    "{{}}"
                placeholder: "[]"
                corpus:      ($c.action.corpus? | default "")
                tools:       ($c.action.tools?  | default [])
                verb:        ($c.action.verb?   | default "Investigate")
                description: $"($c.role.persona) — ($c.role.domain)"
            }
        }
    }
}

# Embed a single text string via the config-aware embedding path in llm.nu.
export def embed-one [text: string] {
    call-llm-embed [$text] | get 0
}

# Run a named prompt (loaded from contracts/*.toml at startup).
# Corpus pre-retrieval is performed when the prompt declares a corpus path.
# Tools are passed to ai-send via --function; write tools are stripped unless
# verb == "Enact".
export def run [name: string, prompt: string] {
    let p = ($env.AI_PROMPTS | get -o $name)
    if ($p | is-empty) {
        error make { msg: $"nu-agent: unknown prompt '($name)' — available: ($env.AI_PROMPTS | columns | str join ', ')" }
    }
    let corpus = ($p.corpus? | default "")
    let verb   = ($p.verb?   | default "Investigate")
    let tools  = ($p.tools?  | default [])
    let allowed = if $verb == "Enact" {
        $tools
    } else {
        $tools | where { |t| $t not-in $WRITE_TOOLS }
    }
    let context = if $corpus != "" { retrieve-context $corpus $prompt } else { "" }
    let system = if $context != "" {
        $"($p.system)\n\nRelevant documentation:\n\n($context)"
    } else {
        $p.system
    }
    let s = (data session)
    let r = ($prompt | ai-send -s $s --system $system --function $allowed --oneshot)
    $r.result.content
}

# Pre-retrieve top-k corpus chunks for a prompt; returns concatenated text
# or empty string when the corpus file is absent.
def retrieve-context [corpus_path: string, prompt: string, k: int = 5] {
    if not ($corpus_path | path exists) {
        print --stderr $"warning: corpus '($corpus_path)' not found; skipping retrieval"
        return ""
    }
    let qv = (embed-one $prompt)
    let hits = (open $corpus_path | rag similarity --query $qv --k $k)
    $hits | get text | str join "\n\n---\n\n"
}

# check_nu_syntax: write to temp file, run `nu --ide-check`, return diagnostics or "OK".
def tool-check-nu-syntax [args: record] {
    let code = ($args.code? | default "")
    if $code == "" { return "tool error: requires non-empty `code`" }
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
        $"nu --ide-check exited with code ($result.exit_code) and no output"
    }
}

# Lexical containment check: true if p lives at or below cwd after path expansion.
def is-under-cwd [p: string] {
    let cwd_abs = (pwd | path expand)
    let p_abs   = ($p | path expand)
    $p_abs == $cwd_abs or ($p_abs | str starts-with ($cwd_abs + "/"))
}

# find_files: glob within cwd, reject escapes, cap at 100 results.
def tool-find-files [args: record] {
    let pat = ($args.pattern? | default "")
    if $pat == "" { return "tool error: requires non-empty `pattern`" }
    let raw = (try { glob $pat } catch { null })
    if $raw == null { return $"tool error: glob failed for pattern '($pat)'" }
    let in_scope = ($raw | where { |p| is-under-cwd $p })
    let count = ($in_scope | length)
    if $count == 0 { return "(no matches)" }
    if $count > 100 {
        $"($in_scope | first 100 | str join "\n")\n\n... ($count - 100) more matches truncated"
    } else {
        $in_scope | str join "\n"
    }
}

# read_file: cwd-scoped, line-numbered, 2000-line default cap.
def tool-read-file [args: record] {
    let raw_path = ($args.path? | default "")
    if $raw_path == "" { return "tool error: requires non-empty `path`" }
    if not (is-under-cwd $raw_path) {
        return $"tool error: path '($raw_path)' resolves outside the working directory"
    }
    let abs = ($raw_path | path expand)
    if not ($abs | path exists) { return $"tool error: file '($raw_path)' not found" }
    let info = (try { ls $abs | get 0 } catch { null })
    if $info == null { return $"tool error: could not stat '($raw_path)'" }
    if $info.type != "file" { return $"tool error: '($raw_path)' is not a regular file (type: ($info.type))" }
    let text = (try { open --raw $abs | decode utf-8 } catch { null })
    if $text == null { return $"tool error: '($raw_path)' is not valid UTF-8 text" }
    let all_lines = ($text | lines)
    let total     = ($all_lines | length)
    let offset    = ($args.offset? | default 1)
    let limit     = ($args.limit?  | default 2000)
    let start_idx = (if $offset > 0 { $offset - 1 } else { 0 })
    let slice     = ($all_lines | skip $start_idx | take $limit)
    let returned  = ($slice | length)
    if $returned == 0 {
        return $"# ($raw_path) — empty range (offset ($offset), file has ($total) lines)"
    }
    let numbered = ($slice | enumerate | each { |row|
        $"($start_idx + $row.index + 1)\t($row.item)"
    } | str join "\n")
    $"# ($raw_path) — lines ($start_idx + 1)–($start_idx + $returned) of ($total)\n($numbered)"
}

# propose_edit: verify old_string matches exactly once, write .proposed companion file.
# Multiple edits to the same path stack cumulatively on the .proposed file.
def tool-propose-edit [args: record] {
    let raw_path   = ($args.path?       | default "")
    let old_string = ($args.old_string? | default "")
    let new_string = ($args.new_string? | default "")
    let rationale  = ($args.rationale?  | default "")
    if $raw_path == ""   { return "tool error: requires non-empty `path`" }
    if $old_string == "" { return "tool error: requires non-empty `old_string`" }
    if $rationale == ""  { return "tool error: requires `rationale`" }
    if not (is-under-cwd $raw_path) {
        return $"tool error: path '($raw_path)' resolves outside the working directory"
    }
    let abs = ($raw_path | path expand)
    if not ($abs | path exists) {
        return $"tool error: file '($raw_path)' not found — for new files use propose_write"
    }
    let proposed_path = ($abs + ".proposed")
    let source_path   = if ($proposed_path | path exists) { $proposed_path } else { $abs }
    let source_label  = if ($proposed_path | path exists) { $"($raw_path).proposed" } else { $raw_path }
    let text = (try { open --raw $source_path | decode utf-8 } catch { null })
    if $text == null { return $"tool error: '($source_label)' is not valid UTF-8" }
    let occurrences = (($text | split row $old_string | length) - 1)
    if $occurrences == 0 {
        let new_count = if $new_string != "" { ($text | split row $new_string | length) - 1 } else { 0 }
        if $new_count >= 1 {
            let msg = $"\(already applied\) ($raw_path).proposed already contains this change. Next action: write the final answer."
            print --stderr $msg
            return $msg
        }
        return $"tool error: old_string not found in '($source_label)' — verify exact whitespace"
    }
    if $occurrences > 1 {
        return $"tool error: old_string matches ($occurrences) times — add surrounding context to make it unique"
    }
    $text | str replace $old_string $new_string | save --raw --force $proposed_path
    let preview = $"# proposed edit to ($raw_path)\n# rationale: ($rationale)\n# written to ($raw_path).proposed\n--- old\n($old_string)\n--- new\n($new_string)\n---"
    print --stderr $preview
    $"\(proposal recorded\) ($raw_path) → ($raw_path).proposed. Do NOT repeat this old_string. Next action: write the final answer.\n  rationale: ($rationale)"
}

# propose_write: verify file does NOT exist, write .proposed companion file.
def tool-propose-write [args: record] {
    let raw_path  = ($args.path?      | default "")
    let content   = ($args.content?   | default "")
    let rationale = ($args.rationale? | default "")
    if $raw_path == ""  { return "tool error: requires non-empty `path`" }
    if $rationale == "" { return "tool error: requires `rationale`" }
    if not (is-under-cwd $raw_path) {
        return $"tool error: path '($raw_path)' resolves outside the working directory"
    }
    let abs = ($raw_path | path expand)
    if ($abs | path exists) {
        return $"tool error: '($raw_path)' already exists — use propose_edit instead"
    }
    $content | save --raw --force ($abs + ".proposed")
    let preview = $"# proposed new file: ($raw_path)\n# rationale: ($rationale)\n# written to ($raw_path).proposed\n--- content\n($content)\n---"
    print --stderr $preview
    $"\(proposal recorded\) ($raw_path).proposed written. Do NOT repeat this path. Next action: write the final answer.\n  rationale: ($rationale)"
}

# Show metadata for a loaded prompt.
export def info [name: string] {
    let p = ($env.AI_PROMPTS | get -o $name)
    if ($p | is-empty) {
        error make { msg: $"nu-agent: unknown prompt '($name)'" }
    }
    {
        name:        $name
        verb:        ($p.verb?        | default "Investigate")
        corpus:      ($p.corpus?      | default "")
        tools:       ($p.tools?       | default [])
        description: ($p.description? | default "")
    }
}

export def main [verb: string, name: string, prompt: string] {
    match $verb {
        "run" => (run $name $prompt)
        _ => { error make { msg: $"engine: unknown verb '($verb)'. Use: nu engine.nu run <name> <prompt>" } }
    }
}
