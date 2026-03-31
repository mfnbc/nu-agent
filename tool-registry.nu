use ./tools.nu *

export const TOOLS = [
  "read-file"
  "write-file"
  "list-files"
  "search"
  "replace-in-file"
  "propose-edit"
  "apply-edit"
  "check-nu-syntax"
]

export def get-tools [] {
  tool-commands
}
