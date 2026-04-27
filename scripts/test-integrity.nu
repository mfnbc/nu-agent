# scripts/test-integrity.nu
# Round-trip Integrity Test for nu_plugin_rag

# 1) Build & register plugin (one-time):
#    cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
#    plugin add ./crates/nu_plugin_rag/target/debug/nu_plugin_rag

# 2) Create three inline records, embed (mock), save, remove, load, and search
[ { id: "a", text: "alpha beta gamma" } , { id: "b", text: "beta yellow fruit" } , { id: "c", text: "rust code plugin" } ]
| rag embed --mock --column text
| rag index-create integrity_test
| rag index-add integrity_test

# Save
rag index-save integrity_test --path /tmp/integrity.msgpack

# Remove from memory
rag index-remove integrity_test

# Load back
rag index-load integrity_test --path /tmp/integrity.msgpack

# Run a search and print result
let results = (rag index-search integrity_test "alpha" --mock --with-doc -f text -k 3)
echo $results

# Basic assertion: top doc should contain 'alpha'
let top_text = ($results | first | get doc | into string)
if ($top_text | str contains "alpha") {
    echo "INTEGRITY PASS"
} else {
    echo "INTEGRITY FAIL"
    exit 1
}
