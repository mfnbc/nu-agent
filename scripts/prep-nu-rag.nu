#!/usr/bin/env nu

# Prep and build a RAG artifact for Nushell docs (wrapper)

source ./scripts/rag.shim.nu

export def main [
  --input: string = "https://github.com/nushell/nushell.github.io.git"
  --out-dir: string = "build/rag/nu-docs"
  --attach-code-blocks
  --force
] {
  echo "{\"step\": \"prepare-deps\"}" | from json

  # Call rag.prepare-deps if available, otherwise print guidance
  if (scope commands | any { |c| $c.name == "rag.prepare-deps" }) {
    rag.prepare-deps --out-dir $nu.env.NU_AGENT_MODEL_DIR? | echo
  } else {
    echo "{\"warning\": \"rag.prepare-deps not available; run it after plugin installation\"}" | from json
  }

  echo "{\"step\": \"build\"}" | from json

  if (scope commands | any { |c| $c.name == "rag.build" }) {
    rag.build --input $input --out-dir $out_dir --attach-code-blocks $attach_code_blocks --force $force
  } else {
    echo "{\"error\": \"rag.build not available; install nu_plugin_rag\"}" | from json
    1
  }
}
