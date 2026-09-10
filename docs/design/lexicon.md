# Runic Indexer and Lexicon Internals

This document describes the internal design of the Runic Indexer, the
template function that powers dynamic infrastructure discovery in
Runik Platform. You will find the selection algorithm explained step by step,
the query signature, the return format, and annotated examples showing
how glyphs call the indexer.

For user-facing documentation on registering lexicon entries and writing
selectors, see [../usage/lexicon.md](../usage/lexicon.md). This document
is for platform engineers who need to understand or modify the indexer
itself.

## Source Location

The Runic Indexer is a single Go template function defined in:

```
charts/glyphs/runic-system/templates/_runic-indexer.tpl
```

It is packaged inside the `runic-system` Helm library chart
(`charts/glyphs/runic-system/Chart.yaml`). Any chart that depends on
`runic-system` can call the indexer with `include`.

## Query Signature

You call the Runic Indexer through the standard Helm `include` function.
It takes a single list argument with four positional elements:

```go
include "runic-system.runic-indexer" (list
  $lexicon    // Dictionary: all lexicon entries
  $selectors  // Dictionary: label selectors {access: external}
  $type       // String: type filter (istio-gw, vault, database, etc.)
  $chapter    // String: current chapter name (for chapter defaults)
)
```

### Parameters

| Position | Name | Type | Description |
|----------|------|------|-------------|
| 0 | `$lexicon` | dict | The full lexicon dictionary from `$root.Values.lexicon`. Each key is an entry name; each value is a dictionary with `type`, `labels`, and type-specific data fields. |
| 1 | `$selectors` | dict | Label selectors to match against entry labels. Pass an empty `dict` if you have no selectors and want the default fallback. |
| 2 | `$type` | string | Infrastructure type filter. Only entries whose `.type` field equals this value are considered. |
| 3 | `$chapter` | string | Name of the current chapter. Used to resolve chapter-level defaults when no exact match or book default is found. |

### Return Format

The indexer returns a JSON string. Parse it with `fromJson` and extract
the `results` key:

```json
{
  "results": [
    {
      "name": "external-gateway",
      "type": "istio-gw",
      "gateway": "infrastructure/external-gateway",
      "labels": {
        "access": "external",
        "default": "book"
      }
    }
  ]
}
```

The `results` array contains zero or more lexicon entry dictionaries.
Each entry retains all of its original fields (`type`, `labels`, and
every data field). If the original entry did not have a `name` field,
the indexer injects one using the dictionary key.

## Selection Algorithm

The indexer evaluates every entry in the lexicon dictionary in a single
pass. It maintains three lists: `$results` (exact matches),
`$bookDefault` (book-level fallbacks), and `$chapterDefault`
(chapter-level fallbacks).

### Step 1 -- Filter by Type

For each entry in the lexicon, the indexer checks whether
`$currentGlyph.type` equals the requested `$type`. Entries with a
different type are skipped entirely. All subsequent steps apply only to
entries that pass the type filter.

```go
{{- if eq $currentGlyph.type $type -}}
```

### Step 2 -- Exact Match (AND Logic)

If the caller provided at least one selector label (`len $selectors > 0`),
the indexer tests every selector against the entry's labels. ALL selector
labels must be present in the entry labels with matching values. This is
strict AND logic -- a single mismatch disqualifies the entry.

```go
{{- $allSelectorsMatch := true -}}
{{- range $selector, $value := $selectors -}}
  {{- if not (and (hasKey $currentGlyph.labels $selector)
                  (eq (index $currentGlyph.labels $selector) $value)) -}}
    {{- $allSelectorsMatch = false -}}
  {{- end -}}
{{- end -}}
{{- if and (gt (len $selectors) 0) $allSelectorsMatch -}}
  {{- $results = append $results $currentGlyph -}}
{{- end -}}
```

Key behaviors:

- An empty selector dict (`len $selectors == 0`) never produces an exact
  match. The condition `gt (len $selectors) 0` gates the append.
- Extra labels on the entry do not prevent a match. The entry only needs
  to contain all selector labels; it can have additional labels.
- When multiple entries satisfy all selectors, all of them are appended
  to `$results`.

### Step 3 -- Collect Default Fallbacks

While iterating, the indexer also collects default entries as potential
fallbacks. Defaults are only collected when no exact match has been found
yet (`len $results == 0`).

```go
{{- if and (hasKey $currentGlyph.labels "default") (eq (len $results) 0) -}}
  {{- if eq (index $currentGlyph.labels "default") "book" -}}
    {{- $bookDefault = append $bookDefault $currentGlyph -}}
  {{- else if and (eq $currentGlyph.chapter $chapter)
                  (eq (index $currentGlyph.labels "default") "chapter") -}}
    {{- $chapterDefault = append $chapterDefault $currentGlyph -}}
  {{- end -}}
{{- end -}}
```

Two kinds of defaults exist:

- **Book default** -- The entry has the label `default: book`. It serves
  as a fallback for any query of this type, regardless of chapter.
- **Chapter default** -- The entry has the label `default: chapter` AND
  its `.chapter` field matches the `$chapter` argument. It serves as a
  fallback only when the query originates from that chapter.

### Step 4 -- Resolve Final Results

After the loop finishes, if `$results` is still empty (no exact matches
were found), the indexer promotes one of the fallback lists:

```go
{{- if (eq (len $results) 0) -}}
  {{- if (eq (len $chapterDefault) 0) -}}
    {{- $results = $bookDefault -}}
  {{- else -}}
    {{- $results = $chapterDefault -}}
  {{- end -}}
{{- end -}}
```

The priority order is:

| Priority | Condition | Source |
|----------|-----------|--------|
| 1 (highest) | At least one exact match exists | `$results` (exact matches) |
| 2 | No exact match; chapter default exists for this chapter | `$chapterDefault` |
| 3 (lowest) | No exact match; no chapter default | `$bookDefault` |

Note: if an exact match was found, chapter and book defaults are
discarded even if they were collected.

### Step 5 -- Serialize and Return

The final results list is wrapped in a dictionary and serialized to JSON:

```go
{{- dict "results" $results | toJson -}}
```

## Multi-Select Behavior

The indexer does not stop at the first match. When multiple lexicon
entries satisfy all selectors for the requested type, every matching
entry appears in the `results` array. Glyphs that call the indexer
decide how to handle multiple results:

- Most glyphs iterate over all results with `range`, generating one
  Kubernetes resource per result (for example, one VirtualService per
  matching gateway).
- Some glyphs take only the first result with `index $results 0`.
- The `databaseEngine` template in the vault glyph queries two different
  types (`vault` and `postgres`) and nests the ranges to produce a
  cross-product of configurations.

## How Glyphs Call the Runic Indexer

Every glyph that depends on infrastructure discovery follows the same
pattern. You call `include "runic-system.runic-indexer"`, pipe the result
through `fromJson`, and extract `"results"`.

### Vault Glyph

The vault glyph discovers vault servers to create secrets, policies, and
database engines:

```go
{{/* In vault glyph -- vault-secret.tpl */}}
{{- define "vault.secret" -}}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1 }}
{{- $vaultServer := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.selector)
    "vault"
    $root.Values.chapter.name
  ) | fromJson) "results" }}
{{- range $vaultConf := $vaultServer }}
  {{/* Generate vault secret resources using $vaultConf fields */}}
{{- end }}
{{- end -}}
```

The `(default dict $glyphDefinition.selector)` guard ensures that when
a spell does not define a `selector` field, an empty dictionary is passed
instead of `nil`. An empty dictionary triggers the default fallback path
(Step 3 and Step 4 in the algorithm above).

### Istio Glyph

The istio glyph discovers gateways to generate VirtualService resources:

```go
{{/* In istio glyph -- virtual-service.tpl */}}
{{- define "istio.virtualService" }}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1}}
{{- if $glyphDefinition.enabled }}
{{- $gateways := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.selector)
    "istio-gw"
    $root.Values.chapter.name
  ) | fromJson) "results" }}
{{- range $gateway := $gateways }}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: {{ default (include "common.name" $root) $glyphDefinition.nameOverride }}-{{ $gateway.name }}
spec:
  gateways:
    - {{ $gateway.gateway }}
  hosts:
    - {{ $glyphDefinition.subdomain }}.{{ $gateway.baseURL }}
{{- end }}
{{- end }}
{{- end }}
```

Each matching gateway produces a separate VirtualService. The template
pulls `gateway` and `baseURL` directly from the lexicon entry returned
by the indexer.

### Cert Manager Glyph

```go
{{- $issuers := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.selector)
    "cert-issuer"
    $root.Values.chapter.name
  ) | fromJson) "results" }}
{{- range $issuer := $issuers }}
  {{/* Generate Certificate resource using $issuer fields */}}
{{- end }}
```

### External Secrets Glyph

The external-secrets glyph is type-agnostic. It reads the provider type
from the glyph definition and passes it directly as the `$type` argument:

```go
{{- $providerType := $glyphDefinition.provider.type }}
{{- $providerServers := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.provider.selector)
    $providerType
    $root.Values.chapter.name
  ) | fromJson) "results" }}
```

### Vault Database Engine (Multi-Indexer)

Some glyphs query the indexer more than once with different types:

```go
{{- $vaultServer := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.selector)
    "vault"
    $root.Values.chapter.name
  ) | fromJson) "results" }}
{{- $postgresServers := get (include "runic-system.runic-indexer" (list
    $root.Values.lexicon
    (default dict $glyphDefinition.postgresSelector)
    "postgres"
    $root.Values.chapter.name
  ) | fromJson) "results" }}
{{- range $vaultConf := $vaultServer }}
{{- range $pgConf := $postgresServers }}
  {{/* Generate resources for each vault + postgres combination */}}
{{- end }}
{{- end }}
```

## Label Matching in Detail

Selector matching follows a strict subset rule: every key-value pair in
the selector dictionary must exist in the entry's `labels` dictionary
with the same value. The entry may have additional labels that are not
in the selector -- those are ignored.

### Matching Rules

| Selector | Entry Labels | Match? | Reason |
|----------|-------------|--------|--------|
| `{access: external}` | `{access: external, env: prod}` | Yes | Selector label present and matching |
| `{access: external, env: prod}` | `{access: external, env: prod}` | Yes | Both selector labels match |
| `{access: external, env: prod}` | `{access: external}` | No | Entry missing `env` label |
| `{access: external}` | `{access: internal}` | No | Value mismatch |
| `{}` (empty) | `{access: external}` | No | Empty selector never matches |

### Why Empty Selectors Do Not Match Everything

The algorithm requires `len $selectors > 0` before it appends an exact
match. This prevents an empty selector from matching every entry of the
requested type. Instead, an empty selector always falls through to the
default resolution chain. Without this guard, a glyph definition that
omits `selector` would receive every lexicon entry of that type, which
is almost never the intended behavior.

## Complete Walkthrough: Query Resolution

Consider the following lexicon with four `istio-gw` entries:

```yaml
lexicon:
  staging-external:
    type: istio-gw
    labels:
      access: external
      environment: staging
    gateway: istio-system/staging-external
    baseURL: staging.example.com

  prod-external:
    type: istio-gw
    labels:
      access: external
      environment: production
    gateway: istio-system/prod-external
    baseURL: example.com

  book-gateway:
    type: istio-gw
    labels:
      access: public
      default: book
    gateway: istio-system/book-gateway
    baseURL: book.example.com

  chapter-gateway:
    type: istio-gw
    labels:
      access: public
      default: chapter
    chapter: staging
    gateway: istio-system/chapter-gateway
    baseURL: chapter.staging.example.com
```

### Query A -- Exact match with two selectors

```yaml
selectors: {access: external, environment: staging}
type: istio-gw
chapter: staging
```

Walk through each entry:

1. **staging-external** -- type matches `istio-gw`. Check selectors:
   `access: external` matches, `environment: staging` matches. All
   selectors match. Append to `$results`.
2. **prod-external** -- type matches. Check selectors:
   `access: external` matches, `environment: production` does not equal
   `staging`. Not all selectors match. Skip.
3. **book-gateway** -- type matches. Check selectors:
   `access: public` does not equal `external`. Not all selectors match.
   Skip. `$results` is not empty, so defaults are not collected.
4. **chapter-gateway** -- type matches. Check selectors:
   `access: public` does not equal `external`. Skip. Defaults not
   collected.

Final result: `[staging-external]`.

```json
{
  "results": [
    {
      "name": "staging-external",
      "type": "istio-gw",
      "labels": {"access": "external", "environment": "staging"},
      "gateway": "istio-system/staging-external",
      "baseURL": "staging.example.com"
    }
  ]
}
```

### Query B -- No exact match, chapter default

```yaml
selectors: {access: unknown}
type: istio-gw
chapter: staging
```

Walk through each entry:

1. **staging-external** -- `access: external` does not equal `unknown`. No
   match. `$results` is empty; check defaults. No `default` label. Skip.
2. **prod-external** -- `access: external` does not equal `unknown`. No
   match. No `default` label. Skip.
3. **book-gateway** -- `access: public` does not equal `unknown`. No match.
   `$results` is empty. Has `default: book`. Append to `$bookDefault`.
4. **chapter-gateway** -- `access: public` does not equal `unknown`. No
   match. `$results` is empty. Has `default: chapter` and
   `.chapter == staging` matches `$chapter`. Append to `$chapterDefault`.

Post-loop: `$results` is empty. `$chapterDefault` is not empty, so
`$results = $chapterDefault`.

Final result: `[chapter-gateway]`.

### Query C -- No exact match, no chapter default, book default

```yaml
selectors: {access: unknown}
type: istio-gw
chapter: production
```

Same iteration as Query B, but `$chapter` is now `production`.

- **chapter-gateway** has `.chapter: staging`, which does not equal
  `production`. It is not added to `$chapterDefault`.

Post-loop: `$results` is empty. `$chapterDefault` is empty.
`$results = $bookDefault`.

Final result: `[book-gateway]`.

### Query D -- Empty selector, chapter default

```yaml
selectors: {}
type: istio-gw
chapter: staging
```

The empty selector has `len == 0`, so the exact-match condition
`and (gt (len $selectors) 0) $allSelectorsMatch` is always false. No
entry is added to `$results`. Defaults are collected as before.

Post-loop: `$results` is empty. `$chapterDefault` contains
`chapter-gateway`. `$results = $chapterDefault`.

Final result: `[chapter-gateway]`.

### Query E -- Multiple exact matches

```yaml
selectors: {access: external}
type: istio-gw
chapter: staging
```

1. **staging-external** -- `access: external` matches. Append to
   `$results`.
2. **prod-external** -- `access: external` matches. Append to `$results`.
3. **book-gateway** -- `access: public` does not match. `$results` is not
   empty, so defaults not collected.
4. **chapter-gateway** -- `access: public` does not match.

Final result: `[staging-external, prod-external]`. Both entries are
returned because both satisfy the single selector label.

## Edge Cases

### Entry Without a Name Field

If a lexicon entry does not have an explicit `name` field, the indexer
injects one using the dictionary key:

```go
{{- if not (hasKey $currentGlyph "name") -}}
  {{- $_ := set $currentGlyph "name" $glyphName -}}
{{- end -}}
```

This ensures every entry in the results array always has a `.name` field
that templates can reference.

### No Matches at All

When no exact match, no chapter default, and no book default are found,
`$results` remains empty. The indexer returns:

```json
{"results": []}
```

Some glyphs handle this gracefully (external-secrets creates a dummy
server); others will fail with `index $results 0` if they assume at
least one result. You should always register at least one default entry
for each type you use.

### Default Collection Timing

Defaults are only collected while `$results` is still empty. If an exact
match is found partway through the iteration, later entries with
`default: book` or `default: chapter` are not appended to the fallback
lists. This is an optimization: once you have exact matches, fallbacks
are irrelevant.

However, because Go template maps iterate in non-deterministic order,
this means default collection can vary depending on iteration order if
some entries produce exact matches. In practice this does not matter
because when exact matches exist, all fallback lists are discarded
anyway.

## Cross-References

- [../usage/lexicon.md](../usage/lexicon.md) -- User-facing guide to registering lexicon entries and writing selectors
- [../usage/spells.md](../usage/spells.md) -- Spell anatomy, `appendix` and `localAppendix` fields
- [../usage/bookrack.md](../usage/bookrack.md) -- Book and chapter structure, how the librarian merges lexicon entries
- [kaster.md](kaster.md) -- Glyph orchestrator that dispatches glyph definitions to templates
- [librarian.md](librarian.md) -- Two-pass processing, appendix collection, and lexicon assembly
- [glyphs.md](glyphs.md) -- Glyph anatomy and how glyphs consume lexicon data
- [merge-system.md](merge-system.md) -- Cascading merge, appendix vs localAppendix scoping
