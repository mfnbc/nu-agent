# Configuration cascade for nu-agent.
#
# Precedence (highest first):
#   1. NU_AGENT_* env-var overrides on leaf scalars
#   2. ./config.local.toml                — repo-local, gitignored
#   3. ~/.config/nu-agent/config.toml     — user-global (XDG-style)
#   4. ./config.toml                       — committed repo defaults
#   5. fallback values in this module
#
# Relative paths inside a config file are resolved against that file's
# directory. Hardcoded fallback paths resolve against this module's
# directory (the repo root).

const HERE = (path self | path dirname)

# Hardcoded fallback config. Used when no config file is found.
def fallback-config [] {
  {
    chat: {
      url: "http://172.19.224.1:1234/v1/chat/completions"
      model: "google/gemma-4-31b"
      timeout: "10min"
    }
    embedding: {
      url: "http://172.19.224.1:1234/v1/embeddings"
      model: "text-embedding-mxbai-embed-large-v1"
      batch_size: 64
    }
    shred: {
      tokenizer_path: ($HERE | path join "tokenizers" "mxbai.json")
      max_tokens: 480
      overlap_tokens: 50
    }
    engine: {
      default_contract: ($HERE | path join "contracts" "architect.toml")
    }
  }
}

# True if a path looks absolute or tilde-anchored.
def is-rooted-path [p: string] {
  ($p | str starts-with "/") or ($p | str starts-with "~")
}

# Resolve known path-valued keys (shred.tokenizer_path, engine.default_contract)
# to absolute paths against base_dir. Other values pass through unchanged.
def resolve-paths [cfg: record, base_dir: string] {
  mut out = $cfg
  for path in [["shred" "tokenizer_path"] ["engine" "default_contract"]] {
    let cp = ($path | into cell-path)
    let val = ($out | get -o $cp)
    if $val != null and not (is-rooted-path $val) {
      $out = ($out | upsert $cp ($base_dir | path join $val | path expand))
    }
  }
  $out
}

# Two-level merge: each section in `over` either overrides or merges with `base`.
def merge-config [base: record, over: record] {
  mut out = $base
  for section in ($over | columns) {
    let bs = ($base | get -o $section | default {})
    let os = ($over | get $section)
    if ($bs | describe) =~ "^record" and ($os | describe) =~ "^record" {
      $out = ($out | upsert $section ($bs | merge $os))
    } else {
      $out = ($out | upsert $section $os)
    }
  }
  $out
}

# Read one TOML config layer; returns null if the file doesn't exist.
def read-layer [path: string] {
  if not ($path | path exists) { return null }
  let dir = ($path | path dirname)
  let raw = (open $path)
  resolve-paths $raw $dir
}

# Apply env-var overrides for known leaf scalars.
def apply-env-overrides [cfg: record] {
  mut out = $cfg
  let mappings = [
    [["chat" "url"] NU_AGENT_CHAT_URL]
    [["chat" "model"] NU_AGENT_CHAT_MODEL]
    [["embedding" "url"] NU_AGENT_EMBEDDING_URL]
    [["embedding" "model"] NU_AGENT_EMBEDDING_MODEL]
    [["shred" "tokenizer_path"] NU_AGENT_TOKENIZER_PATH]
    [["engine" "default_contract"] NU_AGENT_DEFAULT_CONTRACT]
  ]
  for m in $mappings {
    let v = ($env | get -o ($m | get 1) | default "")
    if $v != "" {
      $out = ($out | upsert (($m | get 0) | into cell-path) $v)
    }
  }
  $out
}

# Resolve and return the final merged config record.
export def get-config [] {
  let user_dir = (try { $env.HOME | path join ".config" "nu-agent" } catch { "" })

  # Lowest-to-highest priority; each merge overwrites the previous.
  let layer_paths = [
    ($HERE | path join "config.toml")
    (if $user_dir != "" { $user_dir | path join "config.toml" } else { "" })
    ($HERE | path join "config.local.toml")
  ]

  mut cfg = (fallback-config)
  for p in $layer_paths {
    if $p == "" { continue }
    let layer = (read-layer $p)
    if $layer != null {
      $cfg = (merge-config $cfg $layer)
    }
  }

  apply-env-overrides $cfg
}
