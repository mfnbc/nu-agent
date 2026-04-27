# Contracts

This document defines what a **contract** is, enumerates the core contracts nu-agent ships with, specifies the system-prompt template for each, and describes how contracts compose.

A contract narrows the aperture of a single nu-agent invocation so that the LLM's behaviour, the data it sees, the tools it can call, and the output it must produce are all specified up front. Every invocation of nu-agent chooses exactly one contract.

## The contract tuple

A contract is a specific tuple describing Role and Action Scope.

- Domain: Defines the LLM's expertise, specialty or discipline
- Role: Defines the LLM's persona (e.g., Consultant, Developer, Operator).
- Action Scope: Defines what the LLM can do:
  - Consult: Provide analysis or prose (read-only).
  - Investigate: Search and retrieve data (read + query).
  - Enact: Execute commands to manipulate data (read + write/execute).:
- Corpus: General body of knowledge for the LLM, directory locations of local respositories and even repositories that are vectorized for direct RAG query results injection.
- Tool-set — which Nushell commands the LLM is allowed to call. The default tool-set is a small whitelist (`TOOL_NAMES` in `tools.nu`); individual contracts may extend the whitelist with domain tools from a wing.
- Output-shape — what must come back from the LLM. Choices: a JSON array of tool-calls, a single validated record, a `.try` preview file, or prose.

The execution shape (e.g., sequential, plan-then-execute, loop) should be defined within the contract. 

This makes the contract a complete specification: it dictates not just what data and tools are available, but how the LLM's output is processed and executed (e.g., single tool-call, DAG of calls, iterative refinement).


## Why strictness is the feature

The rules in this document — JSON-only output, whitelist, propose-before-apply, single-record enrichment, no shell drift, strict output validation — read as a pile of restrictions, but they are the opposite of that. They are what makes each invocation **narrow enough to stack**. UNIX `cat` stacks because it does one thing. If the nu-agent primitive tried to do two things, the skyscraper this ecosystem is trying to build would fall over. Every strict rule here is a narrowness decision that buys compositional power elsewhere.

## See also

- [VISION.md](VISION.md) — the ecosystem this contract model serves.
- [ARCHITECTURE.md](ARCHITECTURE.md) — where each contract is implemented in the code.
- [../RULES.md](../RULES.md) — the shortest-possible list of hard invariants.
- [RAG.md](RAG.md) — the retrieval pipeline Ingest-Operator maintains.
