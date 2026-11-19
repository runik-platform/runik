# AGENTS.md — Runik

This is the root guide for working in the runik repository. Per-chart deep dives live in each chart's own `AGENTS.md`; this file is the index and the place where cross-cutting concepts are defined once.

> If a term looks unfamiliar, check [docs/vocabulary.md](docs/vocabulary.md) first.

## 1. What Runik Is

Runik is a GitOps framework that turns short YAML files (**spells**) into ArgoCD Applications built from Helm charts. It separates two audiences: **spell authors** declare *what* they want deployed, and **glyph authors** encode reusable infrastructure patterns on the platform side.

A minimal workload spell is one file with `name:` and `image:`. Adding a block like `vault:` or `istio:` to the same spell pulls in production-grade infrastructure without the spell author touching Kubernetes manifests.

## 2. Vocabulary

All terms are defined in [docs/vocabulary.md](docs/vocabulary.md). Terms you will meet before finishing this file: **spell**, **book**, **chapter**, **appendix**, **localAppendix**, **lexicon**, **runicIndexer**, **glyph**, **summon**, **kaster**, **trinket**, **rune**.

## 3. Repo Layout & Where to Read Next

| Path | What it is | Deep-dive |
|------|------------|-----------|
| `bookrack/` | User-authored spells | [docs/usage/bookrack.md](docs/usage/bookrack.md) |
| `librarian/` | Spell → ArgoCD Application orchestrator | `librarian/AGENTS.md` |
| `charts/summon/` | Default trinket: workloads + internal glyph dispatch | `charts/summon/AGENTS.md` |
| `charts/kaster/` | Top-level dispatcher for `glyphs:` | `charts/kaster/AGENTS.md` |
| `charts/glyphs/` | Infrastructure subcharts (one per type) | [docs/design/creating-glyphs.md](docs/design/creating-glyphs.md) |
| `charts/trinkets/tarot/` | Workflow composition trinket | `charts/trinkets/tarot/AGENTS.md` |
| `charts/trinkets/microspell/` | Opinionated microservice trinket | `charts/trinkets/microspell/AGENTS.md` |
| `covenant/` | IAM system (Keycloak + Vault) | `covenant/AGENTS.md` |

### Submodule rule

`charts/glyphs` is the **canonical** copy of the glyphs repository. Five mirror worktrees check out the same `glyphs.git` at different paths: `charts/kaster/charts`, `charts/summon/charts`, `charts/trinkets/microspell/charts`, `charts/trinkets/tarot/charts`, and `covenant/charts`. Always edit the canonical path and merge its PR into `glyphs/upstream`. The repository-owned Glyphs synchronization Workflow then validates and propagates that exact commit through every consumer and finally this aggregate repository. Never edit a mirror worktree directly; the manual cascade in `docs/design/creating-glyphs.md` is recovery procedure only.

Glyphs is the one repository that intentionally has no root `AGENTS.md`. Its
repository root is checked out verbatim as the consumers' `charts/` directory,
where Helm interprets a top-level Markdown file as a packaged subchart. Keep
agent guidance here and in `docs/design/creating-glyphs.md`; adding ordinary
files or directories at the Glyphs root must first be validated in every
consumer.

## 4. The Two Glyph-Dispatch Mechanisms

Runik has two independent glyph dispatchers. They are not a pipeline — a spell picks one or the other based on which primary source it uses. The choice is mechanical.

### 4.1 Summon-internal dispatcher

- **Trigger**: a subchart name used as a top-level key of the spell (`vault:`, `cert-manager:`, `istio:`, ... at the spell root).
- **Location**: `charts/summon/templates/summon.yaml:21-32`.
- **Output**: rendered inside the summon source. No extra ArgoCD source is created.

### 4.2 Top-level kaster dispatcher

- **Trigger**: entries under the `glyphs:` key of the spell.
- **Location**: `charts/kaster/templates/kaster.yaml:8-14`.
- **Output**: emitted as a separate kaster source on the generated ArgoCD Application.

### 4.3 Which one to use

The rule follows directly from the primary source of the spell:

- Spell uses summon (no `chart:`, no `path:`) → declare infrastructure at the **top level** of the spell. Do **not** use `glyphs:`.
- Spell uses a custom or external chart (`chart:` + `repository:`, or `path:`) → summon does not run. Declare infrastructure under the **`glyphs:`** key.

The dispatch convention (`<chart>.<type>`) is identical in both cases; only the YAML location differs.

## 5. Source-Selection Decision Table

| Spell has... | Primary source | Extra sources |
|--------------|----------------|---------------|
| `path:` | path source | + trinket sources + runes |
| `chart:` + `repository:` | external chart | + trinket sources + runes |
| neither | summon (defaultTrinket) | + trinket sources + runes |
| top-level subchart keys (`vault:`, ...) | handled inside summon | (no extra source created) |
| `glyphs:` | unchanged primary | + kaster source |
| `tarot:` | unchanged primary | + tarot source |
| `runes: [...]` | unchanged primary | + per-rune sources |

### Note on librarian "unset"

When librarian assembles values for the summon source, it `unset`s trinket keys (`glyphs`, `tarot`, `runes`, `appendix`, `localAppendix`). This is routing plumbing, not deletion — each key is passed to its own source or merged into the consolidated appendix. Top-level subchart keys (`vault:`, `cert-manager:`, ...) stay in the summon values because that is where summon's internal dispatcher reads them.

## 6. Lexicon & runicIndexer

The lexicon is a global feature of runik, like glyphs. It applies across the whole framework, not to a particular chart.

### 6.1 What it is

A registry for any resource a spell wants other spells to discover dynamically: gateways, vaults, databases, storage backends, clusters, IAM bindings, or anything else a glyph chooses to publish or consume.

### 6.2 Two registration scopes — `appendix` vs `localAppendix`

- `appendix.lexicon` — visible to **all** spells in the book. Merged in librarian Pass 1 into the global appendix.
- `localAppendix.lexicon` — visible only to its declaring scope (chapter `index.yaml` or a single spell). Applied in Pass 2 as an override on top of the global appendix.

Final precedence (low → high, last write wins):

```
book.appendix → chapter.appendix → spell.appendix →
chapter.localAppendix → spell.localAppendix
```

### 6.3 Anatomy of a lexicon entry

```yaml
lexicon:
  my-entry:
    type: <string>          # required — used as type filter by the indexer
    labels:                 # optional — operational metadata for selectors
      <k>: <v>
      default: book         # optional fallback marker (book | chapter)
    # ...arbitrary payload fields read by consumer glyphs
```

### 6.4 Consuming the lexicon — runicIndexer

- Helper: `charts/kaster/charts/runic-system/templates/_runic-indexer.tpl`.
- Signature: `(lexiconDict, selectors, typeFilter, chapterName) → { results }`.

Match priority:

1. All selectors match (AND logic).
2. Label `default: book` (book-wide fallback, if no exact match).
3. Label `default: chapter` (chapter-scoped fallback).

Selector key lookup, per key:

1. `entry.labels[key]`.
2. `entry[key]` — top-level fallback. Certain glyphs make use of this to inject structural keys (for example a backend-type identifier) into their selector; see the relevant chart's `AGENTS.md` for concrete examples.

### 6.5 Worked example

An infra spell registers an entry in `appendix.lexicon`. An app spell uses a glyph whose selector matches the entry's labels. The indexer returns the entry. The glyph renders against the entry's payload — no hardcoded references in the app spell.

For the full walkthrough see [docs/usage/lexicon.md](docs/usage/lexicon.md).

## 7. Spell Author Quick-Start

When starting a content repository, follow [Create a book in your own repository](docs/usage/bookrack.md#create-a-book-in-your-own-repository). Use that repository's Git workflow and render its book there. Runik's `make render book` target covers registered fixture books.

| Goal | Shape of the spell | Where to learn the full options |
|------|---------------------|---------------------------------|
| Minimal workload | `name` and an `image` map with `name` and `tag` | `charts/summon/AGENTS.md` |
| Workload + inline infra | top-level subchart keys (`vault:`, `istio:`, ...) | [docs/usage/glyphs.md](docs/usage/glyphs.md) |
| External chart + infra | `chart:` + `repository:` + `glyphs:` | `charts/kaster/AGENTS.md` |
| Path-based source | `path:` | [docs/usage/spells.md](docs/usage/spells.md) |
| Extra sources | `runes:` | [docs/usage/runes.md](docs/usage/runes.md) |
| Workflow composition | `tarot:` | `charts/trinkets/tarot/AGENTS.md` |
| Publish / read from lexicon | `appendix.lexicon` / `localAppendix.lexicon` | [docs/usage/lexicon.md](docs/usage/lexicon.md) |

## 8. Glyph Developer Quick-Start

- Edit the canonical path (`charts/glyphs/`). After its reviewed PR is merged
  into `glyphs/upstream`, its native Workflow validates and propagates that exact commit to
  every consumer and then to Runik. Manual submodule bumps are recovery-only.
- A glyph subchart contains `Chart.yaml`, `templates/`, and its test inputs in `examples/`. Put chart defaults in `values.yaml` when needed.
- Before adding a glyph or type, read the closest existing glyph's template and example. Reuse its operations and the helpers in `charts/glyphs/common/templates/`.
  For new glyph resource names, use `common.glyph.name` with named arguments `root`, `glyph` and optional `options`; compose resource affixes through `options.prefix` / `options.suffix` and glyph affixes through `namePrefix` / `nameSuffix`. Reuse the resolved name in every reference to that resource. Keep `common.name` for the existing workload identity and preserve existing names and selectors when adopting the new helper. Normalization is opt-in (`options.normalize`); use `common.name.normalize` for an already composed name only when the resource contract permits it. See [resource naming](docs/design/creating-glyphs.md#resource-names-with-common).
  Use `common.all.labels` for resource metadata, `common.selectorLabels` for stable selectors, and `common.annotations.map` to merge root, resource and generated annotations.
- Dispatch contract: the template named `<chart>.<type>` is invoked when a spell declares an entry with `type: <type>` under either the matching top-level key (summon-internal) or under `glyphs.<chart>` (top-level kaster). One template works in both modes.
- Read the lexicon via `runicIndexer`; see §6.4.
- Render a glyph example from the Runik root with `make render glyph <glyph> <file>` and compare it with its snapshot using `make test glyph <glyph> <file>` (see §10). For example, `postgresql/examples/db.yaml` in Glyphs maps to `tests/snapshots/glyphs/postgresql/db.yaml.snap` in Runik.

Full guide: [docs/design/creating-glyphs.md](docs/design/creating-glyphs.md) and [docs/design/glyphs.md](docs/design/glyphs.md).

## 9. Forgejo-first development and publication

Forgejo is the source of truth for Runik and every component. Start work from
`origin/upstream`, push a topic branch to Forgejo, and merge a reviewed PR into
`upstream`. Do not develop against or push directly to the generated
`runik-platform` GitHub repositories.

An `upstream` merge and a version release are separate operations:

- A Librarian, Covenant, Summon, Kaster, Tarot, or Microspell merge triggers
  its `.argo/synchronize.yaml`, which validates the aggregate and updates its
  Runik gitlink through a CI-gated merge as `ci-bot`.
- A Glyphs merge triggers the serialized Glyphs cascade through all direct
  consumers and Runik. Do not update those gitlinks manually during normal
  development.
- Public publication begins only when a human publishes a Forgejo Release. A
  raw tag push is not a publication request.

Before releasing a chart component, merge an explicit `Chart.yaml` version
change and use the exact tag `v<Chart.yaml.version>`. Glyphs and Runik have
independent SemVer streams. Publish Glyphs first when it is part of a release
set, publish component releases after their commits are pinned in Runik, and
publish the Runik aggregate last.

Repository-owned Workflows export only a clean `upstream` branch and immutable tags to GitHub.
GitHub Actions create the GitHub Releases. Summon, Kaster, Tarot, and
Microspell also publish self-contained OCI Helm charts to
`ghcr.io/runik-platform`; Librarian, Covenant, Glyphs, and Runik are Git-only.

Each repository owns its native lifecycle Workflows under `.argo/`. The
operational contract is the release runbook in
`the-yaml-life/bookrack/the-yaml-life/workflows/README.md`; update it alongside
changes to those Workflows or their shared execution infrastructure.

## 10. Make Targets

Choose local checks by what the diff can affect. For prose edits, review the
diff and any changed links or paths. If an example or command changes, check
that example or command. For a renderer or fixture change, run the narrowest
existing test that exercises the affected behavior. Expand coverage only when
the impact spans more cases or the user requests it. Reuse a passing result
while its inputs and renderer are unchanged.

For every new or changed public behavior, extend the closest example exercised
by the component's existing suite, or add a distinct case alongside it. For
glyphs, these inputs live in `charts/glyphs/<glyph>/examples/`. Check that the
rendered manifest shows the intended behavior, including affected references.
Update a snapshot only when the expected output changes and the render has been reviewed.

The root `Makefile` dispatches resource commands through shell `case` blocks.
The complex integration test delegates once to a private render branch so its
assertions remain defined in one place.

```
make render   {glyph <name> [file] | summon [file] | book <name>}
make snapshot {glyph <name> [file] | summon [file] | book <name> | all}
make test     {glyph <name> [file] | summon [file] | book <name> | integration | covenant | all}
make smoke
make verify
make ci
make list     {glyphs | examples <name> | books}
```

`make ci` is the complete repository gate: submodule and snapshot inventory
verification, direct kaster/trinket smoke renders, all golden snapshots, the
self-contained realistic Librarian integration, and the direct Covenant IAM
suite. See [tests/README.md](tests/README.md) for the coverage matrix,
deterministic render contract, and repository Workflow setup.

## 11. Companion Docs

- [docs/README.md](docs/README.md) — documentation index.
- [docs/vocabulary.md](docs/vocabulary.md) — glossary referenced from this file.
- [docs/usage/](docs/usage/) — spell-author documentation.
- [docs/design/](docs/design/) — internals for framework contributors.
- Each chart's `AGENTS.md` — chart-specific deep dive.
