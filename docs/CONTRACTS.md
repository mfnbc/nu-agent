# Contracts

A contract narrows the aperture of a single nu-agent invocation. Every invocation chooses one.

## The contract tuple

A contract is specified along **two dimensions**: **Role** (who the LLM is) and **Action Scope** (what it may do).

Note: Contracts may also declare retrieval or index tools in `action.tools` — for example, `search_nu_docs` (RAG over msgpack corpora) or `search_ann` (ANN/HNSW retrieval). Declaring `search_ann` requires the contract to provide `index` and `map` arguments when invoking the tool or leave the orchestration to the calling script.
### Role

- **Domain** — expertise or discipline (chess, nutrition, ledger, software, the substrate itself).
- **Persona** — Operator, Consultant, Developer, or a domain-specialised role (Nutritionist, Chess-Coach, Ledger-Auditor, Lexicographer).

### Action Scope

- **Action** — the verb:
  - **Consult** — prose (read-only).
  - **Investigate** — search and retrieve (read + query).
  - **Enact** — execute (read + write).
  - **Enrich** — JSON fill-in (read-only, structured output). The system prompt declares a JSON schema with fields to complete; the user message is the JSON record to enrich; the response is the same record with the declared fields filled in. No corpus retrieval, no tool loop, no free text — JSON in, JSON out.
- **Corpus** — repositories or vectorised reference corpora the LLM may read.
- **Tool-set** — tools the LLM may call (named in the contract's `action.tools` array; engine dispatches whitelisted names against actual implementations).
  - Retrieval tools include `search_nu_docs` (msgpack RAG retrieval) and `search_ann` (ANN/HNSW retrieval). `search_ann` expects `index` and `map` parameters (index basename / id map) and accepts either a `query` string (the engine will embed it) or a `query_vec` list of numbers (precomputed embedding).- **Output-shape** — JSON tool-call array, validated record, `.try` preview, or prose.
- **Execution-shape** — single dispatch, sequential, plan-then-execute, iterative refinement, DAG.

## See also

- [VISION.md](VISION.md) — the ecosystem.
- [STATUS.md](STATUS.md) — current implementation state.
