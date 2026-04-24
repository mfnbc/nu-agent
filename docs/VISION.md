# Vision

**nu-agent is a query tool for the self-describing-record world, and the bootstrapping core of a Nushell-native personal data ecosystem.**

## The problem

Personal data lives in silos. Workouts in one app, finances in another, photos in a third, notes in a fourth, reading history scattered across yet more. Each app defines its own schema and hides it. Cross-domain questions — *did my sleep track with my workouts last month?*, *which of my chess blunders deviate from book theory?*, *how does my grocery ledger correlate with my reading time?* — are expensive or impossible because the data cannot be brought together.

Relational databases solved part of this. SQL could join heterogeneous data, but only after every source had been mapped into a predefined schema. Schema-on-write kept each table clean but made federation rigid. Apache Drill and its kin showed that schema-on-read — letting records carry their own structure — unlocked composition across heterogeneous sources. But Drill still required SQL, and SQL can never answer *what's interesting here?* or *what connects these two corpora?*

LLMs close that last gap. They translate natural-language intent into precise queries over structured data. The combination — **self-describing records + an LLM that translates intent into deterministic tool-calls** — is what SQL-over-schema-on-read always wanted to be but could not. That combination is what nu-agent operates on.

## The substrate

The substrate is **Nushell**. Nushell's native data model is structured records and tables that carry their own field names and types. NUON is its self-describing text format; MessagePack is its portable binary form. Records are queryable without predefined tables; pipelines compose without glue code; plugins written in Rust extend the command set without changing the shape of the data. Nushell is not the query tool — it is the **execution engine and data substrate**. The work SQL used to do (describing queries) is now shared between two cooperating parties: a human stating intent in natural language, and an LLM translating that intent into precise Nushell commands.

## The query tool

**nu-agent is the query tool.** It is to this substrate what `psql` is to PostgreSQL or `sqlite3` is to SQLite — a client that takes a query and returns records. What changes is the query language. Instead of SQL, nu-agent accepts a natural-language prompt plus a contract, routes it through an LLM, and emits JSON tool-calls that execute through Nushell. The shape of each invocation is:

```
(prompt + contract) → LLM → JSON tool-calls → Nushell execution → records
```

One invocation is one query. The primitive is deliberately narrow: single-record in, single validated result out. That narrowness is what makes it composable. Batching, iteration, scheduling, and cross-invocation workflows all happen *outside* nu-agent, in orchestrator scripts that call nu-agent multiple times — the same way `psql` does one query per call and loops happen in shell scripts around it.

## Contracts give the query tool focus

A raw LLM on top of Nushell would be a chatbot with a lot of privileges — too broad to be trustworthy, too loose to be auditable. A **contract** narrows the aperture of a single invocation along four axes:

- **Role** — who the LLM *is*, right now. Operator (emits tool-calls), Consultant (synthesizes prose), Developer (proposes code edits), or a domain-specialized Consultant like Nutritionist or Chess-Coach.
- **Corpus** — which records the invocation is allowed to read. Each role is scoped to the corpora it needs and no others.
- **Tool-set** — which Nushell commands the LLM is allowed to call. The default tool-set is whitelisted; roles may extend the whitelist per-contract.
- **Output-shape** — what must come back: a JSON array of tool-calls, a single validated record, a `.try` preview file, or prose.

A contract is a specific tuple of those four dimensions. Every nu-agent invocation chooses one. See [CONTRACTS.md](CONTRACTS.md) for the full catalogue, the system-prompt templates, and the composition rules.

## The mansion and its wings

nu-agent's core is small and stays small. It is the **carpenter's toolkit**: the primitive that queries, validates JSON, enforces the whitelist, emits `.try` previews, and runs the `enrich` contract. Everything beyond that — domain-specific tools for chess, ledger accounting, astronomy, workouts, bible tokens, the Nushell documentation itself — lives in **wings**, each of which is its own git repository.

A wing typically provides:

- schemas for its domain's records
- Nushell tools (as `def` commands or as `nu_plugin` Rust crates) that operate on those records
- Consultant role definitions scoped to the wing's corpus
- ingestion, reporting, and orchestration scripts

The core does not know about the wings. Wings depend on the core. This keeps the carpenter's toolkit minimal and lets wings evolve, fork, or be replaced without perturbing the primitive.

**Wings are grown, not pre-built.** The most consequential property of this architecture is that nu-agent — through its **developer contract** — is the tool that writes new wings. Under user direction, nu-agent proposes Nushell tools, schemas, consultant prompts, and orchestration scripts as `.try` previews; on explicit confirm, those proposals become committed code in a wing's repository. The popsicle stick builds popsicle sticks. The strictness of the developer contract (propose-before-apply, whitelist discipline, Rust-only-as-`nu_plugin`) is what makes that self-extension safe.

## Three-layer federation

The ecosystem federates at three layers, and all three matter:

**Data federation (within a user).** Self-describing records across every wing — workouts, transactions, chess games, photographs, journal entries, reading notes — are queryable together. A single Consultant session can span any subset of them. This is the within-life join that single-purpose apps cannot do.

**Code federation (across users).** Wings live as independent repositories. Two different users can maintain a ledger wing separately, fork each other's, or swap implementations without disturbing anyone's core nu-agent install. A user assembles their own mansion from whatever wings they choose.

**Knowledge federation (community-wide).** Schemas, Consultant system prompts, and disciplined practices can be published, refined, and adopted across the community. A Budget-Coach prompt that one user tunes over a year becomes reusable by anyone. A canonical transaction-record shape lets independently-built ledger wings interoperate. The crowd thinks together about common problems — budget, health, learning, attention — not by building one monolithic tool, but by sharing the structured practice those tools embody.

## The community precedent

There is good precedent for what this ecosystem is trying to be. Ledger-CLI's community is not just users of a piece of software — it is a community built around a *practice*: plain-text double-entry, append-only, self-auditing. Zettelkasten communities are the same: linked notes as a thinking discipline. What nu-agent enables, at the scale of a life, is that same kind of community for personal data generally — self-describing records as truth, deterministic retrieval as inspection, LLM-mediated reasoning as synthesis. The code is the medium; the practice is what gets shared.

## What nu-agent is not

- **Not a general-purpose coding assistant.** nu-agent is a Nushell-focused query tool. Developer-contract edits are scoped to Nushell code and `nu_plugin` Rust crates; it does not aim to write arbitrary software.
- **Not a chatbot.** Operator output is strict JSON; Consultant output is prose; both are scoped to a contract, not a free conversation.
- **Not a batch engine.** Single-record in, single result out. Batching lives in orchestrator scripts.
- **Not a framework.** There is no plugin API beyond Nushell's own `nu_plugin`. Wings are independent repos, not a dependency-injected registry.
- **Not a database.** The substrate is Nushell tables and files. Persistence is each wing's responsibility.

## Where to go next

- [CONTRACTS.md](CONTRACTS.md) — the contract catalogue, system-prompt templates, composition rules.
- [ARCHITECTURE.md](ARCHITECTURE.md) — technical layers: api, agent core, tool registry, RAG plugin, shredder.
- [../RULES.md](../RULES.md) — hard invariants that apply to every contract.
- [STATUS.md](STATUS.md) — what's implemented, what's in flight, what's a known wart.
- [RAG.md](RAG.md) — the retrieval pipeline walkthrough.
- [DEVELOPER.md](DEVELOPER.md) — build, run, test.
