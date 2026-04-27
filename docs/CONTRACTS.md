# Contracts

A contract narrows the aperture of a single nu-agent invocation. Every invocation chooses one.

## The contract tuple

A contract is specified along **two dimensions**: **Role** (who the LLM is) and **Action Scope** (what it may do).

### Role

- **Domain** — expertise or discipline (chess, nutrition, ledger, software, the substrate itself).
- **Persona** — Operator, Consultant, Developer, or a domain-specialised role (Nutritionist, Chess-Coach, Ledger-Auditor, Lexicographer).

### Action Scope

- **Action** — the verb:
  - **Consult** — prose (read-only).
  - **Investigate** — search and retrieve (read + query).
  - **Enact** — execute (read + write).
- **Corpus** — repositories or vectorised reference corpora the LLM may read.
- **Tool-set** — Nushell commands the LLM may call. Default is the `TOOL_NAMES` whitelist in `tools.nu`; contracts may extend it from a wing.
- **Output-shape** — JSON tool-call array, validated record, `.try` preview, or prose.
- **Execution-shape** — single dispatch, sequential, plan-then-execute, iterative refinement, DAG.

## See also

- [VISION.md](VISION.md) — the ecosystem.
- [ARCHITECTURE.md](ARCHITECTURE.md) — implementation.
- [../RULES.md](../RULES.md) — invariants.
- [RAG.md](RAG.md) — retrieval pipeline.
