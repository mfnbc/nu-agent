# test-edifice.nu
# End-to-end Nushell scripted demo for the nu_plugin_rag "edifice"
#
# Goals:
# 1) Show how to register the plugin (one-time on a machine)
# 2) Ingest a tiny in-memory corpus using native Nushell pipelines
# 3) Run a hydrated search that returns only the `text` field
# 4) Do a simple sanity-check assertion to prove the pipeline works

# ---------------------------
# 0) Build the plugin (outside Nushell)
# ---------------------------
# cargo build -p nu_plugin_rag
# The resulting binary is typically at target/debug/nu_plugin_rag

# ---------------------------
# 1) Register the plugin (one-time; adjust path as needed)
# ---------------------------
# Example (uncomment and edit the path if you want the script to register the plugin):
# plugin add nu_plugin_rag "./target/debug/nu_plugin_rag"

# ---------------------------
# 2) Ingest a tiny mock corpus
# ---------------------------
# Create three inline records, attach embeddings (mock), create an index, and add documents
[ { id: "doc-a" , text: "apple orange fruit salad" } , { id: "doc-b" , text: "banana yellow fruit" } , { id: "doc-c" , text: "computer code rust plugin" } ]
| rag embed --mock --column text
| rag index-create example_docs
| rag index-add example_docs

# ---------------------------
# 3) Hydrated search: return only the `text` field
# ---------------------------
# Use a short text query (mock embedding). We set --with-doc and request field `text`.
let results = (rag index-search example_docs "apple" --mock --with-doc -f text -k 3)

echo "Search results (hydrated, text-only):"
echo $results

# ---------------------------
# 4) Sanity-check: make sure we got at least one hit and the top hit contains the query token
# ---------------------------
# The exact Nushell test primitives vary between versions. This script performs a simple
# runtime check that prints PASS/FAIL so it can be used interactively or in CI.

let top_text = ($results | first | get doc | into string?)

if ($top_text | str contains "apple") {
    echo "EDIFICE TEST PASS: top hit contains query"
} else {
    echo "EDIFICE TEST FAIL: top hit does not contain query"
    exit 1
}

# ---------------------------
# 5) Optional: Call an LLM with the hydrated context
# ---------------------------
# This step requires the repo's api.nu which provides call-llm wrappers. We try to source
# it from the current working directory or a parent directory and skip if not available.
try {
    source ./api.nu
} catch {
    try {
        source ../api.nu
    } catch {
        echo "api.nu not found; skipping LLM generation step"
        exit 0
    }
}

let question = "Provide a one-sentence summary of the context above."
let prompt = ($top_text | into string?)
let body = ($"Use the following context to answer the question:\n\nContext:\n" + $prompt + "\n\nQuestion: " + $question + "\n\nAnswer succinctly.")

try {
    let answer = (call-llm $body [])
    echo "LLM Answer:"
    echo $answer
} catch {
    echo "call-llm failed or not available; skipping LLM generation"
}
