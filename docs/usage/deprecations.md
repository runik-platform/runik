# Deprecations and Compatibility Window

Runik currently accepts a small set of historical names so existing books can
render while new books adopt the canonical kebab-case names. These aliases are
temporary compatibility surfaces, not alternate naming conventions.

> **Deprecation warning:** do not introduce new uses of any legacy name listed
> below. They are kept only for existing books and may be removed in the next
> breaking release after the repository-wide usage audit is clean.

## Deprecated public names

| Deprecated name | Canonical replacement | Compatibility owner |
|-----------------|-----------------------|---------------------|
| `certManager:` | `cert-manager:` | `certManager` library-chart shim |
| `freeForm:` | `free-form:` | `freeForm` library-chart shim |
| Lexicon `type: eventbus` | `type: event-bus` | `argo-events.lexicon-index` |
| Lexicon `type: eventBus` | `type: event-bus` | `argo-events.lexicon-index` |
| Lexicon `type: eventsource` | `type: event-source` | `argo-events.lexicon-index` |
| Lexicon `type: eventSource` | `type: event-source` | `argo-events.lexicon-index` |

The chart-name shims only delegate to the canonical templates; they do not
contain a second implementation. The Argo Events compatibility helper tries the
canonical lexicon type first and consults historical spellings only when no
canonical entry matches. The generic Runic Indexer remains unaware of these
aliases and performs exact type comparisons.

## Deprecated internal helper

`generateSecretPath` is the historical, unnamespaced Vault helper. New templates
must call `vault.secretPath` with an options dictionary. The old helper currently
adapts its positional arguments and delegates to `vault.secretPath`.

```gotemplate
{{/* Deprecated */}}
{{ include "generateSecretPath" (list $root $glyph $vaultConfig "" "kv") }}

{{/* Canonical */}}
{{ include "vault.secretPath" (list $root $glyph $vaultConfig
    (dict "engineType" "kv" "excludeName" false)) }}
```

The wrapper cannot be removed until its remaining internal callers and any
external chart consumers have migrated.

## Renamed without a legacy alias

The following internal names were changed directly and are not compatibility
aliases:

| Removed name | Required name |
|--------------|---------------|
| Chart `runicSystem` | Chart `runic-system` |
| Template `runicIndexer.runicIndexer` | Template `runic-system.runic-indexer` |

All repositories maintained in the Runik workspace have been migrated. External
charts that called the old named template directly must update before consuming
the new glyph bundle.

## Removal checklist

Before removing a compatibility shim or alias:

1. Search maintained books, examples, docs, and downstream charts for the
   deprecated spelling.
2. Render the unchanged compatibility fixture against the canonical charts.
3. Publish the removal as a breaking change and bump the affected major version.
4. Remove the compatibility implementation and its entry from this document in
   the same release.

Useful audit command:

```bash
rg -n 'certManager:|freeForm:|type: eventbus$|type: eventBus$|type: eventsource$|type: eventSource$|generateSecretPath|runicIndexer\.runicIndexer'
```

`vault.prolicy` is not part of this naming deprecation and must not be treated as
a typo or removed under this cleanup.
