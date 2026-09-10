# Merge System

This document describes the cascading merge engine inside the Librarian -- the
Go template logic that resolves book, chapter, and spell configuration into the
final values passed to each ArgoCD Application source.  Everything documented
here lives in `librarian/templates/runik.yaml`.

---

## Cascading Merge: Book < Chapter < Spell

The Librarian applies configuration in three layers.  At every layer, later
values override earlier ones using Helm's `mergeOverwrite` (a recursive
map merge where the right-hand side wins on key conflicts).

```
Book (bookrack/<book>/index.yaml)
  < Chapter (bookrack/<book>/<chapter>/index.yaml)
    < Spell (bookrack/<book>/<chapter>/<spell>.yaml)
```

The rule is simple: **the most specific definition wins**.  A spell can
override anything its chapter set, and a chapter can override anything its book
set.  If a key is absent at a given level, the value from the level above
passes through unchanged.

### What Gets Merged at Each Level

| Level | Configuration Merged |
|-------|---------------------|
| Book | `appParams`, `defaultTrinket`, `trinkets`, `appendix`, `namePrefix`, `nameSuffix`, `clusterSelector` |
| Chapter | `appParams` (override), `defaultTrinket` (override), `trinkets` (override/add), `appendix` (global), `localAppendix` (scoped) |
| Spell | `appParams` (override), all remaining spell fields passed as values to the chart |

---

## Implementation: How mergeOverwrite Drives the Pipeline

The merge engine is implemented entirely in Go templates.  The two core
primitives you see throughout the code are:

- **`mergeOverwrite`** -- recursive map merge, right side wins.
- **`deepCopy`** -- clone a map so mutations do not leak between iterations.

### Step 1: Load the Book

When the Librarian starts, it reads the book's `index.yaml` and merges it into
the initial `$spellbook` dictionary:

```go
{{- $spellbook := dict "appParams" $.Values.appParams }}
{{- $_ := set $spellbook "name" (default $.Release.Name $.Values.name) }}

// Load book config
{{- $path := printf "bookrack/%s/index.yaml" .Values.name }}
{{- $default := .Files.Get $path | fromYaml }}
{{- $_ := mergeOverwrite $spellbook $default }}
```

After this block, `$spellbook` contains the book-level defaults for
`chapters`, `defaultTrinket`, `trinkets`, `appendix`, `appParams`, and every
other field declared in the book's `index.yaml`.

### Step 2: Merge Spell Values on Top of defaultTrinket

When a spell does not declare its own `chart` or `path`, it uses the
`defaultTrinket` chart (typically summon).  The spell's fields are merged on
top of the defaultTrinket's values so the spell can override any default:

```go
// Merge: book < chapter < spell
{{- $values := mergeOverwrite (default dict (deepCopy (default dict $defaultTrinket.values))) $spellDefinition }}
```

This single line implements the "later wins" rule for the values passed to the
primary Helm source.  Because `$spellDefinition` is the right-hand argument,
every key the spell defines takes precedence over the defaultTrinket's
corresponding value.

### Step 3: Merge appParams Across All Three Levels

`appParams` controls ArgoCD Application metadata (sync policy, annotations,
sync waves, etc.) and is merged at every level:

```go
{{- $appParams := deepCopy $spellbook.appParams }}
{{- $_ := mergeOverwrite $appParams (deepCopy (default dict $chapter.appParams)) }}
{{- $_ := mergeOverwrite $appParams (deepCopy (default dict $spellDefinition.appParams)) }}
```

The result is a single `$appParams` dictionary that reflects the book's
defaults, overridden by the chapter, overridden by the spell.

---

## appendix vs localAppendix

The appendix system controls which lexicon entries are visible to each spell.
It operates in two passes.

### appendix (Global Scope)

Any `appendix` block defined at the book, chapter, or spell level is collected
into a single `$globalAppendix` during **Pass 1**.  The result is visible to
**every spell in the entire book**, regardless of which chapter the entry
originated from.

```go
{{/* Pass 1: Collect all appendix into $globalAppendix */}}
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}

{{- range $chapterName := $spellbook.chapters }}
  {{- $chapterDef := $.Files.Get $pathChapter | fromYaml }}
  {{- if $chapterDef.appendix }}
    {{- $_ := mergeOverwrite $globalAppendix (deepCopy $chapterDef.appendix) }}
  {{- end }}

  {{- range $spellPath, $_ := $.Files.Glob $path }}
    {{- $spellDefinition := ($.Files.Get $spellPath | fromYaml) }}
    {{- if $spellDefinition.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $spellDefinition.appendix) }}
    {{- end }}
  {{- end }}
{{- end }}
```

Use `appendix` when a spell creates infrastructure that other chapters need to
discover.  For example, a gateway spell in the `intro` chapter registers
itself so application spells in the `services` chapter can route through it:

```yaml
# bookrack/production/intro/gw-external.yaml
name: external-gateway
# ... chart config ...

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: intro/external-gateway
      baseURL: example.com
```

Every spell in every chapter can now select this gateway via the lexicon.

### localAppendix (Chapter/Spell Scope)

`localAppendix` is **not** collected during Pass 1.  Instead, it is merged
into the final appendix only for spells within the same chapter (or the spell
itself).  Other chapters never see it.

```go
{{/* Pass 2: Build final appendix per-spell */}}
{{- $finalAppendix := deepCopy $globalAppendix }}
{{- if $chapterLocalAppendix }}
  {{- $_ := mergeOverwrite $finalAppendix (deepCopy $chapterLocalAppendix) }}
{{- end }}
{{- if $spellDefinition.localAppendix }}
  {{- $_ := mergeOverwrite $finalAppendix (deepCopy $spellDefinition.localAppendix) }}
{{- end }}
```

The merge order for the final appendix passed to any given spell is:

```
$globalAppendix  <  chapter.localAppendix  <  spell.localAppendix
```

Use `localAppendix` when you need to override a lexicon entry for a subset of
spells without affecting the rest of the book.  A common pattern is overriding
the base URL for a specific chapter:

```yaml
# bookrack/production/internal-apps/index.yaml
localAppendix:
  lexicon:
    external-gateway:
      baseURL: internal.example.com   # Override for this chapter only
```

Spells in `internal-apps` see `baseURL: internal.example.com`.  Spells in
every other chapter still see `baseURL: example.com` from the global appendix.

### Summary Table

| Property | `appendix` | `localAppendix` |
|----------|-----------|-----------------|
| Collected in | Pass 1 (before any Application is generated) | Pass 2 (per-spell, at generation time) |
| Visible to | All spells in all chapters of the book | Only spells in the same chapter (or the spell itself) |
| Merge order | Book appendix < chapter appendix < spell appendix | Global appendix < chapter localAppendix < spell localAppendix |
| Typical use | Register infrastructure (gateways, issuers, databases) | Override a lexicon entry for one chapter |

---

## defaultTrinket and the Chain of Override

`defaultTrinket` tells the Librarian which Helm chart to use when a spell does
not specify its own `chart` or `path`.  It is typically set to summon (the
general-purpose workload chart) but can be any chart.

### Book Sets the Baseline

```yaml
# bookrack/production/index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream
```

Every spell in every chapter inherits this unless overridden.

### Chapter Overrides Specific Fields

A chapter can override any subset of `defaultTrinket` fields.  You do not need
to redeclare every field -- only the ones you want to change:

```yaml
# bookrack/production/applications/index.yaml
defaultTrinket:
  revision: <published-summon-tag-or-commit>
```

### Implementation

The Librarian starts with the book's `defaultTrinket`, then applies the
chapter's override on top:

```go
{{/* Initialize with book-level defaults */}}
{{- $chapterDefaultTrinket := dict }}
{{- if $spellbook.defaultTrinket }}
  {{- $chapterDefaultTrinket = deepCopy $spellbook.defaultTrinket }}
{{- end }}

{{/* Merge chapter override (book < chapter) */}}
{{- if $chapterDef.defaultTrinket }}
  {{- $_ := mergeOverwrite $chapterDefaultTrinket (deepCopy $chapterDef.defaultTrinket) }}
{{- end }}
```

After this merge, `$chapterDefaultTrinket` for the `applications` chapter
contains:

```yaml
repository: https://github.com/runik-platform/summon.git  # from book
path: .                                                   # from book
revision: <published-summon-tag-or-commit>                          # from chapter (overridden)
```

The chapter's `revision` wins; `repository` and `path` pass through from the
book.

### Practical Example

Suppose you want to test a new version of summon in your `staging` chapter
without affecting `infrastructure`:

```yaml
# bookrack/my-book/index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream

chapters:
  - infrastructure   # uses master
  - staging          # will override revision
```

```yaml
# bookrack/my-book/staging/index.yaml
defaultTrinket:
  revision: feature/new-probes   # test branch, only for staging chapter
```

Every spell in `infrastructure` uses `master`.  Every spell in `staging` uses
`feature/new-probes`.  The override is surgical and requires only one line.

---

## Trinkets Override Chain: Book < Chapter

Trinkets (kaster, tarot, and any custom trinkets you register) follow the same
book-then-chapter merge pattern.  They are keyed by their `key` field, which
is the YAML key the Librarian looks for inside each spell to detect that the
trinket should be added as an additional ArgoCD source.

### Book Declares Trinkets

```yaml
# bookrack/production/index.yaml
trinkets:
  kaster:
    key: glyphs
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: upstream
  tarot:
    key: tarot
    repository: https://github.com/runik-platform/tarot.git
    path: .
    revision: upstream
```

### Chapter Overrides or Adds Trinkets

```yaml
# bookrack/production/applications/index.yaml
trinkets:
  kaster:
    key: glyphs
    revision: <published-kaster-tag-or-commit>
```

### Implementation

The Librarian builds a `$chapterTrinketsByKey` map indexed by each trinket's
`key`.  Book trinkets are loaded first, then chapter trinkets are merged on
top:

```go
{{/* Book trinkets */}}
{{- $chapterTrinketsByKey := dict }}
{{- if $spellbook.trinkets }}
  {{- range $name, $trinket := $spellbook.trinkets }}
    {{- if $trinket.key }}
      {{- $_ := set $chapterTrinketsByKey $trinket.key (deepCopy $trinket) }}
    {{- end }}
  {{- end }}
{{- end }}

{{/* Chapter trinkets -- merge on top (book < chapter) */}}
{{- if $chapterDef.trinkets }}
  {{- range $name, $trinket := $chapterDef.trinkets }}
    {{- if $trinket.key }}
      {{- if hasKey $chapterTrinketsByKey $trinket.key }}
        {{- $_ := mergeOverwrite (index $chapterTrinketsByKey $trinket.key) (deepCopy $trinket) }}
      {{- else }}
        {{- $_ := set $chapterTrinketsByKey $trinket.key (deepCopy $trinket) }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
```

If the chapter declares a trinket with the same `key` as a book trinket, the
chapter's fields are merged on top (overriding only what the chapter
specifies).  If the chapter declares a trinket with a new `key`, it is added
to the map and is available only for spells in that chapter.

### Detection at Spell Level

During Pass 2, the Librarian checks whether each spell contains a key matching
a registered trinket.  If it does, a separate ArgoCD source is added for that
trinket:

```go
{{- range $trinketKey, $trinket := $chapterTrinketsByKey }}
  {{- if hasKey $spellDefinition $trinketKey }}
    - repoURL: {{ $trinket.repository }}
      path: {{ $trinket.path }}
      targetRevision: {{ $trinket.revision }}
      helm:
        values: |
          {{ $trinketKey }}:
          {{- toYaml (index $spellDefinition $trinketKey) | nindent 12 }}
  {{- end }}
{{- end }}
```

A spell that contains both `glyphs:` and `tarot:` keys will produce three
ArgoCD sources: the primary source (summon or a custom chart), plus one source
for kaster and one for tarot.

Book- and chapter-level data under a registered key follows the same
`book < chapter` precedence, but Librarian restores it only in the matching
trinket source's context. For example, `chapter.tarot.cards` reaches Tarot but
does not reach summon, kaster, runes, or another trinket. This isolation is
generic for every registered key.

---

## Ordering: Chapters and ArgoCD Sync Waves

### Chapter Ordering

Chapters are processed in the exact order you list them in the book's
`index.yaml`.  The Librarian iterates `$spellbook.chapters` sequentially:

```yaml
chapters:
  - infrastructure    # Processed first
  - databases         # Processed second
  - applications      # Processed third
  - monitoring        # Processed last
```

This ordering affects two things:

1. **Appendix availability** -- because Pass 1 collects appendix from all
   chapters before Pass 2 generates Applications, chapter order does not
   affect lexicon visibility.  All appendix entries are globally available
   regardless of the chapter that defined them.

2. **ArgoCD Application creation order** -- Applications from earlier chapters
   appear first in the rendered manifest.  While ArgoCD does not guarantee
   deployment order based on manifest position alone, you combine this with
   sync waves for deterministic sequencing.

### Sync Waves for Fine-Grained Control

Within a chapter, you control deployment order using ArgoCD sync wave
annotations.  Lower wave numbers deploy first:

```yaml
# bookrack/production/infrastructure/istio.yaml
name: istio
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"   # Deploy very early
```

```yaml
# bookrack/production/infrastructure/cert-manager.yaml
name: cert-manager
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "0"    # Deploy after Istio
```

```yaml
# bookrack/production/infrastructure/s3-csi.yaml
name: s3-csi
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "1"    # Deploy after cert-manager
```

Sync waves are integers (negative values are valid).  ArgoCD processes all
resources in wave N before moving to wave N+1.  You set them via
`appParams.annotations` at the spell level, or at the book/chapter level if
you want a default wave for all spells:

```yaml
# bookrack/production/monitoring/index.yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "50"   # All monitoring spells deploy late
```

Individual spells in the chapter can still override this with their own
`appParams.annotations`.

### Combining Chapters and Sync Waves

A typical production book uses chapters for logical grouping and sync waves
for dependency ordering:

```yaml
# Book index.yaml
chapters:
  - infrastructure   # Gateways, certs, mesh
  - databases        # PostgreSQL, Redis
  - applications     # API services, frontends
  - monitoring       # Prometheus, Grafana

# infrastructure/index.yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "-10"

# databases/index.yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# applications/index.yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "10"

# monitoring/index.yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "50"
```

Within `infrastructure`, individual spells can use waves `-10` through `-1` to
sequence Istio before cert-manager before external-dns.

---

## Complete Merge Flow Diagram

The following shows the full data flow for a single spell:

```
Book index.yaml
  |
  |-- appParams ---------> $spellbook.appParams
  |-- defaultTrinket ----> $spellbook.defaultTrinket
  |-- trinkets ----------> $spellbook.trinkets
  |-- appendix ----------> $globalAppendix (Pass 1)
  |
Chapter index.yaml
  |
  |-- appParams ---------> mergeOverwrite onto $spellbook.appParams
  |-- defaultTrinket ----> mergeOverwrite onto $chapterDefaultTrinket
  |-- trinkets ----------> mergeOverwrite onto $chapterTrinketsByKey
  |-- appendix ----------> mergeOverwrite onto $globalAppendix (Pass 1)
  |-- localAppendix -----> stored as $chapterLocalAppendix
  |
Spell YAML
  |
  |-- appParams ---------> mergeOverwrite onto per-spell $appParams
  |-- appendix ----------> mergeOverwrite onto $globalAppendix (Pass 1)
  |-- localAppendix -----> mergeOverwrite onto per-spell $finalAppendix
  |-- (all other keys) --> mergeOverwrite onto $defaultTrinket.values
  |
  v
Final ArgoCD Application
  |-- source[0]: primary chart (defaultTrinket or custom chart/path)
  |     values: merged $values + cleaned $spellbook context + cleaned $chapter + $lexicon
  |-- source[1..N]: one per detected trinket key (glyphs, tarot, ...)
  |     values: trinket-specific data + its scoped key + cleaned context + $lexicon
  |-- syncPolicy: from merged $appParams
  |-- destination: from $clusterSelector or default cluster
```

---

## Cross-References

- [../usage/bookrack.md](../usage/bookrack.md) -- Book and chapter structure, user-facing merge examples
- [../usage/spells.md](../usage/spells.md) -- Spell YAML fields and spell types
- [../usage/trinkets.md](../usage/trinkets.md) -- Trinket registration and chapter-level defaultTrinket overrides
- [../usage/lexicon.md](../usage/lexicon.md) -- How appendix.lexicon entries enable dynamic infrastructure discovery
- [../usage/deploying.md](../usage/deploying.md) -- How the Librarian processes the bookrack end to end
- [../usage/runes.md](../usage/runes.md) -- Multi-source runes and how they interact with the merge chain
