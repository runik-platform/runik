# Librarian Internals

The Librarian is the core template engine in Runik Platform. It reads every spell
in the bookrack and generates one ArgoCD `Application` resource per spell, each
with the correct combination of Helm sources. The template lives at
`librarian/templates/runik.yaml` and runs in two passes: first it consolidates
all appendix data across the book, then it generates Applications with
multi-source detection.

This document walks through the template code line by line. You should read the
usage docs (`docs/usage/bookrack.md`, `docs/usage/spells.md`) before reading
this file.

## Generated Output Example

Before diving into the code, here is what the Librarian produces. Given a spell
`api-service.yaml` with an image and glyphs, the output is a single ArgoCD
Application with multiple sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service
  namespace: argocd
spec:
  project: example-tdd-project
  sources:
    # Source 1: summon (defaultTrinket) -- the primary workload
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: feature/coding-standards
      helm:
        values: |
          name: api-service
          namespace: applications
          image:
            repository: nginx
            tag: alpine
          service:
            enabled: true
            type: ClusterIP
            ports:
              - port: 80
                protocol: TCP
                name: http
          # Context injected by the Librarian
          spellbook:
            name: example-tdd-book
            chapters:
              - infrastructure
              - applications
          chapter:
            name: applications
          lexicon:
            external-gateway:
              name: external-gateway
              type: istio-gw
              gateway: istio-system/external-gateway

    # Source 2: kaster trinket -- triggered by glyphs: key
    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      targetRevision: feature/coding-standards
      helm:
        values: |
          glyphs:
            istio:
              example-api-vs:
                type: virtualService
                http:
                  - match:
                      - uri:
                          prefix: /api
                    route:
                      - destination:
                          host: example-api
                          port:
                            number: 80
          spellbook:
            name: example-tdd-book
          chapter:
            name: applications
          lexicon:
            external-gateway:
              name: external-gateway
              type: istio-gw
              gateway: istio-system/external-gateway

  destination:
    server: https://kubernetes.default.svc
    namespace: applications
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 2
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Every source receives `spellbook`, `chapter`, and `lexicon` as context. The
workload values go to summon, the glyph definitions go to kaster, and both can
query the lexicon for dynamic infrastructure discovery.


## Template Location

The template file is:

```
librarian/templates/runik.yaml
```

The Librarian is packaged as a Helm chart (`librarian/Chart.yaml`) and uses the
Helm Files API (`$.Files.Glob`, `$.Files.Get`) to read spell definitions from
the `bookrack/` directory at render time.

Supporting files in the `librarian/` chart:

```
librarian/
  Chart.yaml          # Chart metadata (name: librarian, version: 1.2.4)
  values.yaml         # Default appParams (syncPolicy, retry, etc.)
  templates/
    runik.yaml        # Main template -- this document covers this file
    project.yaml      # Generates the ArgoCD AppProject resource
```


## Initialization

Before either pass starts, the template builds the `$spellbook` context dict
and loads the book-level `index.yaml`:

```go
{{- $spellbook :=  dict "appParams" $.Values.appParams  }}
{{- $_ := set $spellbook "name" (default $.Release.Name $.Values.name) }}

{{- $path := printf "bookrack/%s/index.yaml" (default .Release.Name .Values.name) }}
{{- if .Files.Glob $path }}
  {{- $default := .Files.Get $path | fromYaml }}
  {{- $_ := mergeOverwrite $spellbook $default }}
{{- end }}
```

Line by line:

1. Create `$spellbook` with the default `appParams` from `librarian/values.yaml`.
2. Set the book name. If `$.Values.name` is provided, use it; otherwise fall
   back to the Helm release name.
3. Build the path to the book's `index.yaml` (e.g.,
   `bookrack/production/index.yaml`).
4. If the file exists, parse it and merge it into `$spellbook`. After this step,
   `$spellbook` contains `chapters`, `defaultTrinket`, `trinkets`, `appendix`,
   `appParams`, and everything else from the book index.


## Pass 1: Consolidate Appendix

The first pass collects all `appendix` definitions from every level (book,
chapter index, individual spell files) into a single `$globalAppendix` dict.
This must happen before any Application is generated because a spell in chapter
A may register a lexicon entry that a spell in chapter B needs to consume.

### The Code

```go
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}

{{- range $chapterName := $spellbook.chapters }}
  {{- $pathChapter := print "bookrack/" $spellbook.name "/" $chapterName "/index.yaml" }}
  {{- if $.Files.Glob $pathChapter }}
    {{- $chapterDef := $.Files.Get $pathChapter | fromYaml }}
    {{- if $chapterDef.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $chapterDef.appendix) }}
    {{- end }}
  {{- end }}
  {{- $path := print "bookrack/" $spellbook.name "/" $chapterName "/*.y*ml"}}
  {{- range $spellPath, $_ := $.Files.Glob $path }}
    {{- $spellDefinition := ($.Files.Get $spellPath | fromYaml) }}
    {{- if $spellDefinition.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $spellDefinition.appendix) }}
    {{- end }}
  {{- end }}
{{- end }}
```

### Line-by-Line Explanation

```go
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}
```

Start with the book-level appendix. If `$spellbook.appendix` is nil, use an
empty dict. `deepCopy` prevents mutations from leaking back into `$spellbook`.

```go
{{- range $chapterName := $spellbook.chapters }}
```

Iterate over chapters in the order declared in the book's `index.yaml`.

```go
  {{- $pathChapter := print "bookrack/" $spellbook.name "/" $chapterName "/index.yaml" }}
  {{- if $.Files.Glob $pathChapter }}
    {{- $chapterDef := $.Files.Get $pathChapter | fromYaml }}
```

Build the path to the chapter's `index.yaml`. If it exists, parse it. Not every
chapter has an `index.yaml`; the `$.Files.Glob` check prevents errors on
missing files.

```go
    {{- if $chapterDef.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $chapterDef.appendix) }}
    {{- end }}
```

If the chapter index declares an `appendix`, deep-copy it and merge it into the
global. `mergeOverwrite` means chapter-level keys override book-level keys with
the same name.

```go
  {{- $path := print "bookrack/" $spellbook.name "/" $chapterName "/*.y*ml"}}
  {{- range $spellPath, $_ := $.Files.Glob $path }}
    {{- $spellDefinition := ($.Files.Get $spellPath | fromYaml) }}
```

Glob all YAML files in the chapter directory (`*.yaml` and `*.yml` via the
`*.y*ml` pattern). Parse each file as a spell definition.

```go
    {{- if $spellDefinition.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $spellDefinition.appendix) }}
    {{- end }}
```

If any individual spell file declares an `appendix`, merge it into the global.
This is how infrastructure spells (like an Istio gateway) register themselves in
the lexicon for application spells to discover later.

### Why Two Passes?

Consider this scenario:

```
bookrack/production/
  infrastructure/
    gateway.yaml          # appendix: { lexicon: { ext-gw: { type: istio-gw } } }
  applications/
    api-service.yaml      # needs ext-gw from lexicon
```

If you generated Applications in a single pass, `api-service.yaml` would be
processed before `gateway.yaml`'s appendix entry was collected. The two-pass
design ensures the complete lexicon is available to every spell regardless of
file ordering.

### Note: index.yaml Exclusion

In the actual template, the inner loop includes a guard to skip the chapter's
`index.yaml` so it is not processed as a spell:

```go
{{- if not (eq $spellPath (print "bookrack/" $spellbook.name "/" $chapterName "/index.yaml")) }}
```

This prevents the chapter configuration from generating a spurious Application.


## Pass 2: Generate Applications

The second pass iterates over every spell file again, this time generating the
actual ArgoCD Application resources.

### Per-Chapter Setup

For each chapter, the Librarian builds the chapter-level trinket configuration
by merging book-level defaults with chapter-level overrides:

```go
{{- $chapter := dict "name" $chapterName }}
{{- $chapterLocalAppendix := dict }}
{{- $chapterTrinketsByKey := dict }}
{{- $chapterDefaultTrinket := dict }}

{{- if $spellbook.defaultTrinket }}
  {{- $chapterDefaultTrinket = deepCopy $spellbook.defaultTrinket }}
{{- end }}

{{- if $spellbook.trinkets }}
  {{- range $name, $trinket := $spellbook.trinkets }}
    {{- if $trinket.key }}
      {{- $_ := set $chapterTrinketsByKey $trinket.key (deepCopy $trinket) }}
    {{- end }}
  {{- end }}
{{- end }}
```

This creates two critical data structures:

| Variable | Contents | Example |
|----------|----------|---------|
| `$chapterDefaultTrinket` | The chart used when a spell has no `chart:` or `path:` | `{ repository: .../summon.git, path: ., revision: upstream }` |
| `$chapterTrinketsByKey` | Map of trigger keys to trinket definitions | `{ "glyphs": { key: glyphs, repository: .../kaster.git, path: . }, "tarot": { ... } }` |

If the chapter has its own `index.yaml`, it can override these:

```go
{{- if $chapterDef.defaultTrinket }}
  {{- $_ := mergeOverwrite $chapterDefaultTrinket (deepCopy $chapterDef.defaultTrinket) }}
{{- end }}
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

A chapter can change the summon revision, add new trinkets, or override trinket
repository URLs without affecting other chapters.


### Per-Spell Processing

For each spell file in the chapter, the Librarian:

1. Merges `appParams` (book < chapter < spell).
2. Builds the final appendix (global < chapterLocal < spellLocal).
3. Detects which sources to generate.
4. Strips glyph keys from summon values.
5. Outputs the Application YAML.


### Final Appendix Construction

```go
{{- $finalAppendix := deepCopy $globalAppendix }}
{{- if $chapterLocalAppendix }}
  {{- $_ := mergeOverwrite $finalAppendix (deepCopy $chapterLocalAppendix) }}
{{- end }}
{{- if $spellDefinition.localAppendix }}
  {{- $_ := mergeOverwrite $finalAppendix (deepCopy $spellDefinition.localAppendix) }}
{{- end }}
```

The merge order is: `global < chapterLocal < spellLocal`. This means a spell's
`localAppendix` can override a chapter's `localAppendix`, which can override the
global appendix. The `localAppendix` entries are scoped -- they do not propagate
to other chapters or spells.

The lexicon is then extracted from the final appendix, with `.name` ensured on
each entry:

```go
{{- $lexicon := dict }}
{{- if $finalAppendix.lexicon }}
  {{- range $name, $lexiconDef := $finalAppendix.lexicon }}
    {{- if not (hasKey $lexiconDef "name") }}
      {{- $_ := set $lexiconDef "name" $name }}
    {{- end }}
    {{- $lexicon = set $lexicon $name $lexiconDef }}
  {{- end }}
{{- end }}
```


## Detection Logic

The Librarian determines what sources to generate for each spell based on what
keys are present in the spell definition. The detection follows a priority
chain.

### Detection Flowchart

```
spell definition
     |
     v
Has chart: + repository:  ──yes──> External Chart Source
     |                              (use spell's repo/chart/revision)
     no
     |
     v
Has path: + repository:   ──yes──> Custom Chart Path Source
     |                              (use spell's repo/path/revision)
     no
     |
     v
Use defaultTrinket (summon)         Default Source
                                    (use $chapterDefaultTrinket)
```

### Detection Code (Go Template Pseudocode)

```go
{{- if or $spellDefinition.chart $spellDefinition.path }}
  {{/* BRANCH A: Explicit chart or path -- external chart */}}
  - repoURL: {{ $spellDefinition.repository }}
    {{- if $spellDefinition.chart }}
    chart: {{ $spellDefinition.chart }}       # e.g. kube-prometheus-stack
    {{- else }}
    path: {{ $spellDefinition.path }}         # e.g. charts/argo-cd
    {{- end }}
    targetRevision: {{ $spellDefinition.revision }}
    helm:
      values: |
        {{ spell's .values }}
{{- else }}
  {{/* BRANCH B: No chart/path -- use defaultTrinket (summon) */}}
  - repoURL: {{ $chapterDefaultTrinket.repository }}
    path: {{ $chapterDefaultTrinket.path }}     # e.g. ./charts/summon
    targetRevision: {{ $chapterDefaultTrinket.revision }}
    helm:
      values: |
        {{ merged + stripped spell values }}
{{- end }}
```

### Trinket Detection

After the primary source, the Librarian checks if the spell contains any
registered trinket keys. For each trinket registered in `$chapterTrinketsByKey`,
it checks if that key exists in the spell:

```go
{{- range $trinketKey, $trinket := $chapterTrinketsByKey }}
  {{- if hasKey $spellDefinition $trinketKey }}
    {{/* Spell has this trinket key -- add a source */}}
    - repoURL: {{ $trinket.repository }}
      path: {{ $trinket.path }}
      targetRevision: {{ $trinket.revision }}
      helm:
        values: |
          {{ $trinketKey }}:
            {{ data under that key }}
          {{ context (spellbook, chapter, lexicon) }}
  {{- end }}
{{- end }}
```

For example, if `$chapterTrinketsByKey` contains `{ "glyphs": { path:
./charts/kaster, ... } }` and the spell has a `glyphs:` key, the Librarian adds
a kaster source with only the glyph data.

The `glyphs` key receives special treatment -- the data is passed under the
`glyphs:` key directly:

```go
{{- if eq $trinketKey "glyphs" }}
  glyphs:
    {{ glyph data }}
{{- else }}
  {{ $trinketKey }}:
    {{ trinket data }}
{{- end }}
```

### Rune Detection

After trinkets, the Librarian processes `runes`. Each rune follows the same
external-vs-default detection logic:

```go
{{- range $rune := $spellDefinition.runes }}
  {{- if or $rune.chart $rune.path }}
    {{/* Rune has explicit chart/path -- use it directly */}}
    - repoURL: {{ $rune.repository }}
      chart: {{ $rune.chart }}
      targetRevision: {{ $rune.revision }}
      helm:
        values: |
          {{ $rune.values }}
  {{- else }}
    {{/* Rune has no chart/path -- fallback to defaultTrinket (summon) */}}
    - repoURL: {{ $chapterDefaultTrinket.repository }}
      path: {{ $chapterDefaultTrinket.path }}
      targetRevision: {{ $chapterDefaultTrinket.revision }}
      helm:
        values: |
          {{ $rune.values }}
  {{- end }}
{{- end }}
```

This means you can define a rune with only `values:` and the Librarian will
route it through the same summon chart, creating a second independent workload
in the same Application. This is the "rune fallback" pattern, used for
multi-workload spells:

```yaml
# In spell file:
name: multi-workload-app
image:
  repository: my-api
  tag: v1.0.0

runes:
  # Rune fallback: no chart/path, just values -> uses summon
  - values:
      workload:
        type: deployment
      image:
        repository: my-worker
        tag: v1.0.0

  # Rune explicit: has chart -> uses that chart directly
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
    values:
      auth:
        enabled: false
```

### Complete Detection Summary

Given a spell, the Librarian generates sources in this order:

```
Source 1 (always):
  spell has chart:/path:  -->  external chart source
  spell has neither       -->  defaultTrinket (summon) source

Source 2..N (conditional):
  for each trinket key in $chapterTrinketsByKey:
    spell has that key?   -->  trinket source (kaster, tarot, etc.)

Source N+1..M (conditional):
  for each rune in spell.runes:
    rune has chart:/path: -->  external chart source
    rune has neither      -->  defaultTrinket (summon) source
```


## Stripping of Glyph Keys

When the primary source is the defaultTrinket (summon), the Librarian must
remove keys that summon does not understand. Summon is a workload chart -- it
knows about `image:`, `service:`, `workload:`, `envs:`, and similar fields. It
does not know what `glyphs:`, `vault:`, `istio:`, or `tarot:` mean.

If you passed `vault:` to summon, it would either fail or silently ignore it.
Worse, it would bloat the values payload with data meant for kaster. The
Librarian strips these keys before passing values to summon.

### The Stripping Code

```go
{{- $values := mergeOverwrite (default dict (deepCopy (default dict $defaultTrinket.values)) ) $spellDefinition }}
{{- $_ := unset $values "runes" }}
{{- $_ := unset $values "appParams" }}
{{- $_ := unset $values "appendix" }}
{{- $_ := unset $values "localAppendix" }}
{{- range $key, $_ := $chapterTrinketsByKey }}
  {{- $_ := unset $values $key }}
{{- end }}
```

### Line-by-Line Explanation

```go
{{- $values := mergeOverwrite (default dict (deepCopy (default dict $defaultTrinket.values)) ) $spellDefinition }}
```

Start with the defaultTrinket's own default values (if any), then merge the
entire spell definition on top. At this point `$values` contains everything:
workload fields, glyph keys, runes, appParams, appendix, etc.

```go
{{- $_ := unset $values "runes" }}
```

Remove `runes`. Runes are processed as separate sources; summon should not see
them.

```go
{{- $_ := unset $values "appParams" }}
```

Remove `appParams`. These control ArgoCD Application metadata (sync policy,
annotations), not chart values. They are consumed by the Application spec, not
by summon.

```go
{{- $_ := unset $values "appendix" }}
{{- $_ := unset $values "localAppendix" }}
```

Remove `appendix` and `localAppendix`. These are consumed during Pass 1 for
lexicon consolidation. Summon has no use for them.

```go
{{- range $key, $_ := $chapterTrinketsByKey }}
  {{- $_ := unset $values $key }}
{{- end }}
```

Remove every registered trinket key. If `$chapterTrinketsByKey` contains
`"glyphs"` and `"tarot"`, this removes `glyphs:` and `tarot:` from `$values`.
These keys are passed to their respective trinket charts as separate sources.

### What Remains After Stripping

After stripping, `$values` contains only fields that summon understands:

| Kept | Stripped |
|------|---------|
| `name` | `runes` |
| `namespace` | `appParams` |
| `image` | `appendix` |
| `workload` | `localAppendix` |
| `service` | `glyphs` (trinket key) |
| `envs` | `tarot` (trinket key) |
| `volumes` | Any other registered trinket key |
| `probes` | |
| `resources` | |
| `autoscaling` | |
| `secrets` | |
| `serviceAccount` | |

### Important: External Charts Skip Stripping

When the primary source is an external chart (`chart:` or `path:` present in
the spell), the stripping logic does not run. External charts receive only the
`values:` sub-key from the spell, not the entire spell definition. The
Librarian passes `$spellDefinition.values` directly:

```go
{{- if or $spellDefinition.chart $spellDefinition.path }}
  helm:
    values: |
      {{- if $spellDefinition.values }}
      {{- toYaml $spellDefinition.values | nindent 10 }}
      {{- end }}
```

This is why external chart spells use `glyphs:` as a wrapper key for their
infrastructure integrations, rather than placing glyph keys at the top level.


## Context Passing

Every source -- summon, kaster, external chart (with `bookData`), and runes --
receives three context objects injected by the Librarian:

```yaml
# Injected into every source's helm values
spellbook:
  name: production
  chapters:
    - infrastructure
    - applications
  # ... (cleaned: appParams, summon, kaster, appendix removed)

chapter:
  name: applications

lexicon:
  external-gateway:
    name: external-gateway
    type: istio-gw
    gateway: istio-system/external-gateway
    labels:
      access: external
      default: book
  vault:
    name: vault
    type: vault
    url: https://vault.production.svc
```

### What Gets Cleaned from Spellbook

Before injection, the Librarian strips internal-only fields from the spellbook
context:

```go
{{- $cleanSpellbook := merge (dict "spellbook" (deepCopy $spellbook)) }}
{{- $_ =  unset $cleanSpellbook.spellbook "appParams" }}
{{- $_ =  unset $cleanSpellbook.spellbook "summon" }}
{{- $_ =  unset $cleanSpellbook.spellbook "kaster" }}
{{- $_ =  unset $cleanSpellbook.spellbook "appendix" }}
{{- $_ =  unset $cleanSpellbook.spellbook "localAppendix" }}
```

Charts receive the book name, chapters list, and other metadata -- but not the
internal chart references or appendix data (the lexicon is passed separately in
its resolved form).

### Why Charts Need Context

Charts use the injected context for different purposes:

**summon** uses `spellbook.name` and `chapter.name` to build naming conventions,
labels, and annotations. For example, a PVC might be named
`production-applications-my-app-data`.

**kaster** uses the `lexicon` to resolve dynamic references. When a glyph
defines an Istio VirtualService with `selector: { access: external }`, kaster
queries the lexicon to find the gateway that matches those labels.

**tarot** receives only its registered `tarot` subkey plus the same context.
Book- and chapter-level `tarot` values are restored only for that source, so
Tarot can implement scoped card inheritance without leaking large definitions
to unrelated charts.

**External charts** receive context only when the spell sets
`appParams.bookData: true`. Most external charts ignore it, but custom charts
built for runik can use it:

```yaml
# Spell with bookData enabled
name: custom-operator
repository: https://github.com/myorg/charts.git
path: charts/my-operator
revision: main

appParams:
  bookData: true   # Inject spellbook/chapter/lexicon into values

values:
  replicas: 2
```

### Trinket subkey isolation

Before source generation, Librarian removes every registered trinket key from
the common `spellbook` and `chapter` contexts. For a matching trinket source,
it restores only that key:

```go
{{- if hasKey $spellbook $trinketKey }}
  {{- $_ := set $trinketSpellbook.spellbook $trinketKey
        (deepCopy (index $spellbook $trinketKey)) }}
{{- end }}
```

The behavior is key-driven and agnostic to Tarot. Any trinket can use scoped
book or chapter configuration without exposing it to primary, rune, or other
trinket sources. The appendix remains dedicated to the lexicon.


## Full Detection Logic Diagram

Here is the complete decision tree for a single spell, showing every source the
Librarian may generate:

```
spell.yaml
  |
  +-- PRIMARY SOURCE (exactly one)
  |     |
  |     +-- has chart: or path: ?
  |     |     yes --> Source: external chart
  |     |             repoURL: spell.repository
  |     |             chart/path: spell.chart or spell.path
  |     |             values: spell.values + optional context (if bookData)
  |     |
  |     |     no  --> Source: defaultTrinket (summon)
  |     |             repoURL: $chapterDefaultTrinket.repository
  |     |             path: $chapterDefaultTrinket.path
  |     |             values: stripped spell definition + context
  |     |
  +-- TRINKET SOURCES (zero or more)
  |     |
  |     for each trinket in $chapterTrinketsByKey:
  |       |
  |       +-- spell has trinket.key ?
  |             yes --> Source: trinket chart
  |                     repoURL: trinket.repository
  |                     path: trinket.path
  |                     values: { <trinket.key>: <spell data> } + context
  |             no  --> skip
  |
  +-- RUNE SOURCES (zero or more)
        |
        for each rune in spell.runes:
          |
          +-- rune has chart: or path: ?
                yes --> Source: external chart
                        repoURL: rune.repository
                        chart/path: rune.chart or rune.path
                        values: rune.values + context
                no  --> Source: defaultTrinket (summon)
                        repoURL: $chapterDefaultTrinket.repository
                        path: $chapterDefaultTrinket.path
                        values: rune.values + context
```


## Concrete Examples

### Example 1: Pure Summon Spell

Input spell (`bookrack/my-book/apps/api.yaml`):

```yaml
name: api
namespace: apps
image:
  repository: myorg/api
  tag: v1.0
service:
  enabled: true
  ports:
    - port: 8080
```

Detection result: no `chart:`, no `path:`, no trinket keys, no runes.

Generated sources: **1 source** (summon).

### Example 2: Summon + Kaster

Input spell:

```yaml
name: api-service
namespace: services
image:
  repository: example/api-service
  tag: v1.2.3
service:
  enabled: true
envs:
  APP_ENV: production

glyphs:
  vault:
    api-creds:
      type: secret
      format: env
      keys:
        - API_KEY
  istio:
    api-route:
      type: virtualService
      hosts:
        - api.example.com
```

Detection result: no `chart:` -> summon. Has `glyphs:` key -> kaster trinket.

Generated sources: **2 sources** (summon + kaster). The `glyphs:` key is
stripped from summon values and passed to kaster.

### Example 3: External Chart + Kaster

Input spell:

```yaml
name: prometheus-monitoring
namespace: monitoring
repository: https://prometheus-community.github.io/helm-charts
chart: kube-prometheus-stack
revision: 51.3.0

values:
  prometheus:
    enabled: true
  grafana:
    enabled: true

glyphs:
  istio:
    monitoring-route:
      type: virtualService
      hosts:
        - grafana.example.com
```

Detection result: has `chart:` -> external chart. Has `glyphs:` key -> kaster.

Generated sources: **2 sources** (external chart + kaster). External chart
receives only the `values:` sub-key. Kaster receives the `glyphs:` data.

### Example 4: Summon + Kaster + Runes

Input spell:

```yaml
name: payment-service
namespace: applications
image:
  repository: example-registry/payment-service
  tag: v2.1.0
service:
  enabled: true

glyphs:
  istio:
    payment-route:
      type: virtualService
      hosts:
        - api.example.com

runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 17.11.3
    values:
      auth:
        enabled: false

  - repository: https://charts.bitnami.com/bitnami
    chart: postgresql
    revision: 12.8.0
    values:
      auth:
        database: payments
```

Detection result: no `chart:` -> summon. Has `glyphs:` -> kaster. Two runes
with explicit charts.

Generated sources: **4 sources** (summon + kaster + redis + postgresql).

### Example 5: Rune Fallback (Multi-Workload)

Input spell:

```yaml
name: rune-multi-workload
image:
  repository: my-api
  tag: v1.0.0
workload:
  type: deployment
  replicas: 3

runes:
  - values:
      workload:
        type: deployment
        replicas: 5
      image:
        repository: my-worker
        tag: v1.0.0
      envs:
        WORKER_MODE: "true"

  - values:
      workload:
        type: statefulset
        replicas: 1
      image:
        repository: postgres
        tag: "15"
```

Detection result: no `chart:` -> summon. No trinket keys. Two runes without
`chart:/path:` -> both fall back to summon (defaultTrinket).

Generated sources: **3 sources** (summon + summon + summon). Each source
produces an independent workload through the same summon chart.

### Example 6: Infrastructure Only (defaultTrinket + Kaster)

Input spell:

```yaml
name: tdd-certificates
namespace: cert-manager

workload:
  enabled: false

cert-manager:
  example-tdd-wildcard:
    type: certificate
    secretName: example-tdd-cert
    dnsNames:
      - "*.example-tdd.com"
      - "example-tdd.com"
```

Detection result: no `chart:`, no `path:`. The primary source uses
defaultTrinket (summon). The glyph keys (`cert-manager:`) are detected
at the top level and trigger the kaster trinket. Setting `workload.enabled: false`
prevents summon from generating a Deployment.

Generated sources: **2 sources** (summon + kaster). The defaultTrinket always
runs. With `workload.enabled: false`, summon produces no Deployment, leaving
kaster as the source that generates the actual resources.


## Cross-References

- `docs/usage/bookrack.md` -- Book/chapter structure, merge rules, organization patterns
- `docs/usage/spells.md` -- Spell types, field reference, examples of all detection branches
- `docs/design/README.md` -- Document index for all design docs
- `docs/design/merge-system.md` -- Cascading merge internals (appendix, localAppendix, defaultTrinket)
- `docs/design/kaster.md` -- How kaster dispatches glyph definitions to individual glyph templates
- `docs/design/summon-internals.md` -- How summon processes the stripped values into Kubernetes resources
- `docs/design/lexicon.md` -- Runic Indexer selection algorithm, query format, label matching
- `docs/design/rendering-pipeline.md` -- End-to-end flow from spell to Kubernetes resources
- `docs/design/trinkets.md` -- Trinket registration, trigger mechanism, key-based detection
