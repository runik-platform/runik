# Vocabulary

Glossary of terms used across runik. One-line definitions; deeper explanations live in the document each term links to.

| Term | Definition |
|------|------------|
| **spell** | A single YAML file under `bookrack/<book>/<chapter>/` declaring what to deploy. Fundamental unit of configuration. See [usage/spells.md](usage/spells.md). |
| **book** | A top-level directory under `bookrack/`. Usually represents an environment or tenant. Contains an `index.yaml` and chapters. See [usage/bookrack.md](usage/bookrack.md). |
| **chapter** | A subdirectory of a book, grouping related spells. Carries its own `index.yaml` with defaults, ordering, and optional lexicon entries. |
| **appendix** | A block inside `index.yaml` or a spell whose `lexicon:` entries become visible to every spell in the book. Merged in librarian Pass 1. |
| **localAppendix** | Same shape as `appendix`, but visible only to its declaring scope (chapter or spell). Applied in librarian Pass 2 as an override on top of the global appendix. |
| **lexicon** | The consolidated registry of infrastructure references assembled from all `appendix` / `localAppendix` blocks. Injected into every generated ArgoCD source. See [usage/lexicon.md](usage/lexicon.md). |
| **runicIndexer** | Helm template helper (`charts/kaster/charts/runic-system/templates/_runic-indexer.tpl`) that resolves selectors against the lexicon. Returns matching entries filtered by type. |
| **glyph** | A subchart under `charts/glyphs/` that renders a specific kind of infrastructure resource (vault secret, istio VirtualService, certificate, etc.). Invoked by its `type` field. See [usage/glyphs.md](usage/glyphs.md). |
| **summon** | The default trinket (`charts/summon/`). Renders workloads (Deployment, StatefulSet, Job, CronJob, DaemonSet) and also has an internal glyph-like dispatcher triggered by subchart names at the spell root. See [usage/summon.md](usage/summon.md). |
| **kaster** | Top-level chart (`charts/kaster/`) that dispatches items under the `glyphs:` key of a spell to their corresponding glyph subchart. Emitted as its own ArgoCD source. |
| **trinket** | Any chart registered in the book or chapter `index.yaml` under `trinkets:` or `defaultTrinket:`. A trinket is activated either by the presence of its trigger key in a spell (kaster via `glyphs:`, tarot via `tarot:`) or as the default primary source when a spell has no `chart:` / `path:` (summon, or microspell when substituted for summon). Librarian and covenant are not trinkets — they are app renderers with their own invocation model. See [usage/trinkets.md](usage/trinkets.md). |
| **defaultTrinket** | The trinket used when a spell has neither `chart:` nor `path:`. Ships as `summon`. |
| **rune** | An entry in a spell's `runes:` array that adds an extra ArgoCD source (external Helm chart or path-based). See [usage/runes.md](usage/runes.md). |
| **tarot** | Trinket that composes scoped cards into Argo WorkflowTemplate readings. Activated by the `tarot:` key on a spell. See [usage/trinkets.md](usage/trinkets.md#tarot). |
| **card** | One executable process building block owned by Tarot. It contains exactly one native Argo/Kubernetes implementation or template reference and may expose an input/output contract. |
| **reading** | A Tarot process definition that arranges card executions with explicit dependencies. It may be local, inherited as the single effective default, or published by reference for selector-based reuse. |
| **microspell** | Opinionated microservice trinket that pre-wires workload, Vault, Istio, and observability. |
| **covenant** | Deterministic IAM renderer (Keycloak + Vault). One IAM book, Helm release, and Argo CD Application define one complete organization/realm; selected application books publish role and per-realm client contracts. See [usage/trinkets.md](usage/trinkets.md#covenant). |
| **librarian** | Top-level orchestrator chart (`librarian/`). Reads the bookrack in two passes and emits one ArgoCD Application per spell with multiple sources. See [design/librarian.md](design/librarian.md). |
| **bookrack** | The `bookrack/` directory itself — the root of all user-authored configuration. |
| **provider** | A convention used by certain glyphs (external-secrets, vault, aws, s3, ...) of placing a structural identifier at the top level of a lexicon entry so a consuming glyph can route on backend type. Not a global rule; see the relevant chart's `CLAUDE.md` for usage. |
