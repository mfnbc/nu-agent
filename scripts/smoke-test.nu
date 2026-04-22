# Smoke test for nu_plugin_rag: embed (mock) -> index-create -> index-add -> index-search
# This script creates three records, embeds them with deterministic mock embeddings,
# adds them to an in-memory index, then searches the index with a text query.

# Create three simple records on the pipeline
[ { id: "doc-a" , input: "apple orange" } , { id: "doc-b" , input: "banana fruit" } , { id: "doc-c" , input: "computer code" } ]
| rag embed --mock --column input
| rag index-create smoke_test
| rag index-add smoke_test

# Now search by text query (mock embedding)
; rag index-search smoke_test "apple" --mock -k 3
