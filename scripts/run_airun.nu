use ../mod.nu *

# Build a single task that includes the hydrated context and a strict instruction
let ctx = (open build/rag/hydrated_top5.json | get text | str join "\n\n")

let task = (
  "Context: " + $ctx + "\n\nTask: Create a file named docs.nu containing comprehensive documentation and examples derived from the provided Context. " +
  "Emit only a JSON array of Nushell tool calls; do not output prose. The single tool call should be a write-file with path \"docs.nu\" and content containing the documentation. Output exactly one tool call."
)

airun --task $task
