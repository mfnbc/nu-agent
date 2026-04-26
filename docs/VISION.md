# Vision

**nu-agent is a query tool for the self-describing-record world, and the bootstrapping core of a Nushell-native personal data ecosystem.**

The purpose aligns as a kind of a data lakehouse on a personal scale, with unified data access and analysis across many different data types. Our world of different apps for each task an purpose has generated a lot of siloed data.

The greater effort nu-agent belongs to breaks down silos by combining raw, diverse data (like a lake) with structured querying and governance (like a warehouse). The goal is a single source of truth for BI, AI, and cross-domain insights—enabling questions like "How did my sleep affect my workouts?" without app switching. 

For your personal system, the purpose is personal insight through composable, authoritative data exploration, using Nushell as the execution layer instead of SQL.

LLMs close gaps of understanding and insight between and inside datasets. They can translate natural-language inquiry into coded analysis over structured data. The combination — **self-describing records + an LLM that translates intent into deterministic tool-calls** — is what SQL-over-schema-on-read always wanted to be but could not. That combination is what nu-agent operates on.

## The substrate

The substrate is **Nushell**. Nushell's native data model is structured records and tables that carry their own field names and types. NUON is its self-describing text format; MessagePack is its portable binary form. Records are queryable without predefined tables; pipelines compose without glue code; plugins written in Rust extend the command set without changing the shape of the data. Nushell is not the query tool — it is the **execution engine and data substrate**. T

**nu-agent is the insight tool** giving you with LLM assitance the ability to analyse and track your data. It helps you write simple helper apps like a workout tracker, and combine it with a LLM contracted to act as a workout coach to help design workouts. It helps you write a chess database, and gives you the ability to inspect and learn about your personal habits with an LLM contract as a chess coach. 

## Contracts give the query tool focus

A raw LLM on top of Nushell would be a chatbot with a lot of privileges — too broad to be trustworthy, too loose to be auditable, and too little definition to lock out hallucination. A **contract** narrows the aperture of a single invocation along four axes:

- **Role** — who the LLM *is*, right now. Operator (emits tool-calls), Consultant (synthesizes prose), Developer (proposes code edits), or a domain-specialized Consultant like Nutritionist or Chess-Coach.
- **Corpus** — which records the invocation is allowed to read. Each role is scoped to the corpora it needs and no others.
- **Tool-set** — which Nushell commands the LLM is allowed to call. The default tool-set is whitelisted; roles may extend the whitelist per-contract.
- **Output-shape** — what must come back: a JSON array of tool-calls, a single validated record, a `.try` preview file, or prose.

A contract is a specific tuple of those four dimensions. Every nu-agent invocation chooses one. See [CONTRACTS.md](CONTRACTS.md) for the full catalogue, the system-prompt templates, and the composition rules.

## Where to go next

- [CONTRACTS.md](CONTRACTS.md) — the contract catalogue, system-prompt templates, composition rules.
- [ARCHITECTURE.md](ARCHITECTURE.md) — technical layers: api, agent core, tool registry, RAG plugin, shredder.
- [../RULES.md](../RULES.md) — hard invariants that apply to every contract.
- [STATUS.md](STATUS.md) — what's implemented, what's in flight, what's a known wart.
- [RAG.md](RAG.md) — the retrieval pipeline walkthrough.
- [DEVELOPER.md](DEVELOPER.md) — build, run, test.
