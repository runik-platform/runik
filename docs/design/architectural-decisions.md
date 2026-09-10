# Architectural Decisions

This document records the key architectural decisions made in Runik Platform, explaining the context, the decision itself, and the consequences (both benefits and tradeoffs). Each decision shaped a fundamental aspect of how the system works today.

If you are new to Runik Platform, read [architecture.md](architecture.md) first for the system overview, then return here to understand *why* the system is designed the way it is.

---

## 1. Glyphs as Submodules, Not Helm Dependencies

### Context

Glyphs are reusable template libraries that generate Kubernetes resources (VaultSecrets, VirtualServices, Certificates, etc.). The kaster chart orchestrates glyphs by iterating over `glyphs:` values and dispatching to the matching glyph template. In traditional Helm, you would declare each glyph as a dependency in `charts/kaster/Chart.yaml` using the `dependencies:` field and run `helm dependency update` to pull them into `charts/kaster/charts/`.

```yaml
# Traditional approach (NOT what runik does)
# charts/kaster/Chart.yaml
apiVersion: v2
name: kaster
dependencies:
  - name: vault
    version: "1.0.0"
    repository: "file://../glyphs/vault"
  - name: istio
    version: "1.0.0"
    repository: "file://../glyphs/istio"
  # ... every glyph listed here
```

This dependency approach introduces a build step (`helm dep update`), generates `.tgz` archives in the `charts/` directory, and requires version coordination across all glyph Chart.yaml files.

### Decision

Glyphs live canonically in `charts/glyphs/`. Every consumer (`charts/kaster/`, `charts/summon/`, `charts/trinkets/microspell/`, `charts/trinkets/tarot/`, `covenant/`) tracks the same `glyphs.git` repository through a git submodule mounted at the consumer's `charts/` subdirectory. There is no `dependencies:` block in any consumer's `Chart.yaml`; each chart discovers its subcharts by scanning its own `charts/` directory at render time via `$root.Subcharts`.

The result is that each consumer sees every glyph as a plain subdirectory:

```
charts/
  glyphs/                    # Canonical source of truth (also a submodule)
    vault/
    istio/
    cert-manager/
    ...
  kaster/
    Chart.yaml               # No dependencies: block
    templates/
      kaster.yaml            # Dispatches to subcharts via $root.Subcharts
    charts/                   # Submodule of glyphs.git
      vault/
      istio/
      cert-manager/
      ...
```

The kaster dispatch template references these subcharts directly:

```yaml
# charts/kaster/templates/kaster.yaml
{{- range $chartName, $_ := $root.Subcharts }}
  {{- range $glyphName, $glyph := index $root.Values.glyphs $chartName }}
    {{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
  {{- end }}
{{- end }}
```

### Consequences

**Benefits:**

- **Simpler**: You never run `helm dependency update`. There is no dependency resolution, no per-glyph version pinning, and no `Chart.lock` file to maintain.
- **Faster**: No chart downloads or archive extraction. The charts are already on disk as plain directories, ready for `helm template`.
- **Testable**: You test glyphs by rendering the kaster chart directly. Run `helm template charts/kaster/ -f test-values.yaml` and inspect the output. No dependency build step before testing.
- **Single source of truth**: Every consumer points at the same `glyphs.git` commit, so a glyph behaves identically everywhere once the submodule reference is bumped.

**Tradeoffs:**

- **Submodule bumps**: After changing a glyph, you commit and push in the canonical `charts/glyphs/` submodule, then bump the submodule reference in every consumer that needs the change. This is a cross-repo step, not a single commit.
- **Mirror directories exist**: Every glyph is visible under five consumer paths (`charts/kaster/charts/`, `charts/summon/charts/`, `charts/trinkets/microspell/charts/`, `charts/trinkets/tarot/charts/`, `covenant/charts/`) — all pointing at the same `glyphs.git`. Only the canonical path (`charts/glyphs/`) should be edited.

---

## 2. Multi-Source ArgoCD Applications

### Context

A typical runik application needs multiple Helm charts working together. A spell with `image:` and `vault:` needs both the summon chart (for the Deployment and Service) and the kaster chart (for VaultSecrets and VirtualServices). Traditional Helm solves this with `Chart.yaml` dependencies (umbrella charts), where a parent chart bundles sub-charts into a single deployable unit.

```yaml
# Traditional umbrella chart approach (NOT what runik does)
# umbrella/Chart.yaml
apiVersion: v2
name: my-app-umbrella
dependencies:
  - name: summon
    version: "1.0.0"
    repository: "file://../../charts/summon"
  - name: kaster
    version: "1.0.0"
    repository: "file://../../charts/kaster"
  - name: redis
    version: "18.0.0"
    repository: "https://charts.bitnami.com/bitnami"
```

This umbrella approach requires committing `.tgz` archives to Git, running `helm dep update` before every deployment, and sharing a single monolithic values structure across all sub-charts.

### Decision

Use ArgoCD multi-source Applications. Each chart that a spell needs becomes a separate `sources:` entry in the generated ArgoCD Application manifest. The librarian detects which charts are needed based on the spell's keys and produces the correct source list.

For a spell like this:

```yaml
# bookrack/production/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

vault:
  db-creds:
    path: secret/data/production/db

runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
```

The librarian generates an ArgoCD Application with three sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service
  namespace: argocd
spec:
  sources:
    # Source 1: summon (defaultTrinket) -- Deployment, Service
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          name: api-service
          image: myorg/api:v1.0
          # vault: key stripped -- passed to kaster instead

    # Source 2: kaster (trinket triggered by glyphs/vault key) -- VaultSecret
    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          glyphs:
            vault:
              db-creds:
                path: secret/data/production/db
          lexicon: { ... }

    # Source 3: redis (rune) -- Redis StatefulSet
    - repoURL: https://charts.bitnami.com/bitnami
      chart: redis
      targetRevision: 18.0.0
      helm:
        values: |
          # rune values here
```

Runes replace Helm dependencies. Instead of bundling a Redis chart as a `Chart.yaml` dependency, you declare it as a rune, and the librarian appends it as an additional ArgoCD source.

### Consequences

**Benefits:**

- **No `.tgz` binaries in Git**: ArgoCD fetches each chart directly from its repository at sync time. Your Git repository contains only YAML.
- **No `helm dependency update`**: There is no build step. The librarian generates declarative Application manifests; ArgoCD handles chart resolution.
- **Per-source sync policies**: Each source in the Application has its own `targetRevision`. You can pin summon to `v1.2.5`, kaster to `master`, and redis to `18.0.0` independently.
- **Granular ArgoCD UI visibility**: The ArgoCD dashboard shows each source separately. You can see which source is out-of-sync, which source failed, and drill into each chart's rendered resources independently.
- **GitOps-native**: The entire system is declarative YAML in Git. No imperative build commands, no artifact storage, no chart museum.

**Tradeoffs:**

- **Requires ArgoCD**: Multi-source Applications are an ArgoCD feature. You cannot render the full multi-source output with plain `helm template` alone. The librarian generates ArgoCD Application manifests, not raw Kubernetes resources. If you move away from ArgoCD, you need to replace the multi-source mechanism.
- **Newer ArgoCD feature**: Multi-source Application support was introduced in ArgoCD 2.6 and became stable in 2.7. Older ArgoCD installations do not support it. You must run ArgoCD 2.6 or later.

---

## 3. Lexicon for Dynamic Discovery

### Context

Infrastructure resources -- Istio Gateways, Vault servers, database endpoints, certificate issuers -- need to be referenced by application spells. Without a discovery mechanism, every spell must hard-code the infrastructure details:

```yaml
# Without lexicon -- hard-coded references
name: api-service
image: myorg/api:v1.0

istio:
  route:
    gateway: istio-system/staging-gateway    # Hard-coded
    hosts:
      - api.staging.example.com              # Hard-coded

vault:
  db-creds:
    url: https://vault.staging.svc:8200      # Hard-coded
    authPath: k8s-staging-auth               # Hard-coded
    path: secret/data/staging/db             # Hard-coded
```

When you move this spell to production, you must rewrite every reference. When a gateway is renamed, every spell that references it must be updated. This creates tight coupling between application spells and infrastructure configuration.

### Decision

Infrastructure registers itself in a **lexicon** via `appendix.lexicon` entries. Application spells discover infrastructure via **label selectors**. The **Runic Indexer** (`runic-system.runic-indexer`) queries the lexicon at render time, matching selectors against labels using AND logic.

**Registration** -- infrastructure spells publish their details to the lexicon:

```yaml
# bookrack/production/infrastructure/gateway.yaml
name: external-gateway
repository: https://github.com/istio/istio.git
path: manifests/charts/gateways/istio-ingress
revision: 1.23.0

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: istio-system/external-gateway
      baseURL: example.com
```

**Discovery** -- application spells find infrastructure by selector:

```yaml
# bookrack/production/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

istio:
  route:
    selector:
      access: external    # Finds external-gateway from lexicon
    subdomain: api
```

The Runic Indexer runs inside glyph templates. When the istio glyph encounters a `selector`, it calls the indexer:

```
runicIndexer(lexicon, {access: external}, "istio-gw", chapterName)
```

The indexer filters all lexicon entries by `type: istio-gw`, then matches `labels.access: external` using AND logic, and returns the matching entries. The glyph template uses the returned `gateway` and `baseURL` fields to generate the VirtualService.

If no exact match is found, the indexer falls back to defaults:

```
1. Exact match       -- selector labels match entry labels
2. Chapter default   -- entry with label default: chapter in the same chapter
3. Book default      -- entry with label default: book
```

### Consequences

**Benefits:**

- **Decoupling**: Application spells never hard-code infrastructure references. You can rename a gateway, change a Vault URL, or move a database without editing any application spell.
- **Flexibility**: When infrastructure changes, you update the lexicon entry in one place. Every spell that discovers it via selector automatically picks up the new values on the next render.
- **Environment portability**: The same spell works in dev, staging, and production. Each book registers its own lexicon entries for its infrastructure. The spell `selector: {access: external}` finds the right gateway regardless of which book it runs in.

```
bookrack/
  staging/
    infrastructure/
      gateway.yaml       # lexicon: baseURL: staging.example.com
    apps/
      api-service.yaml   # selector: {access: external} -> staging gateway
  production/
    infrastructure/
      gateway.yaml       # lexicon: baseURL: example.com
    apps/
      api-service.yaml   # selector: {access: external} -> production gateway
```

**Tradeoffs:**

- **Indirection**: You cannot look at a spell and immediately see which gateway it uses. You must check the lexicon entries to understand what `selector: {access: external}` resolves to in each book.
- **Debugging requires checking merged lexicon**: When a selector returns unexpected results, you need to inspect the merged lexicon (global + chapter local + spell local) to understand which entries are visible and which labels match. Use `helm template librarian/ --set name=<book> --debug` to see the full merged values.
- **Labels must be carefully coordinated**: If two infrastructure spells register lexicon entries with overlapping labels and the same type, the indexer may return both. Label naming conventions must be established and followed across the team.

---

## 4. Two-Pass Librarian Processing

### Context

The librarian reads a bookrack and generates one ArgoCD Application per spell. Spells can register lexicon entries via `appendix.lexicon`, and other spells in the same book can discover those entries via selectors. The problem: in a single-pass approach, the librarian processes spells sequentially. If spell A in chapter `infrastructure` registers a gateway in the lexicon, and spell B in chapter `applications` uses a selector to find that gateway, the outcome depends on processing order. If spell B is processed before spell A, the gateway entry does not exist yet and the selector fails.

```
Single-pass problem:

Chapter: applications
  api-service.yaml        # selector: {access: external} -> NOT FOUND (gateway not collected yet)

Chapter: infrastructure
  gateway.yaml            # appendix.lexicon: external-gateway (collected here, too late)
```

Even if chapters are processed in order, entries from later spells within the same chapter would be missed. The fundamental issue is that a single pass interleaves collection and resolution.

### Decision

The librarian runs two passes over the bookrack. Pass 1 collects all `appendix.lexicon` entries from every level (book index, chapter indices, and every spell file). Pass 2 generates ArgoCD Applications with the complete lexicon available to every spell.

The two-pass logic is implemented in `librarian/templates/runik.yaml`:

```yaml
# PASS 1: Collect all appendix from chapters and files
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}

{{- range $chapterName := $spellbook.chapters }}
  # Collect chapter index appendix
  {{- if $chapterDef.appendix }}
    {{- $_ := mergeOverwrite $globalAppendix (deepCopy $chapterDef.appendix) }}
  {{- end }}

  # Collect every spell file appendix
  {{- range $spellPath, $_ := $.Files.Glob $path }}
    {{- if $spellDefinition.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $spellDefinition.appendix) }}
    {{- end }}
  {{- end }}
{{- end }}

# PASS 2: Generate Applications with complete $globalAppendix
{{- range $chapterName := $spellbook.chapters }}
  {{- range $spellPath, $_ := $.Files.Glob $path }}
    # Build final appendix: global < chapterLocal < fileLocal
    {{- $finalAppendix := deepCopy $globalAppendix }}
    {{- if $chapterLocalAppendix }}
      {{- $_ := mergeOverwrite $finalAppendix (deepCopy $chapterLocalAppendix) }}
    {{- end }}
    {{- if $spellDefinition.localAppendix }}
      {{- $_ := mergeOverwrite $finalAppendix (deepCopy $spellDefinition.localAppendix) }}
    {{- end }}

    # Generate ArgoCD Application with $finalAppendix.lexicon available
    ---
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    ...
  {{- end }}
{{- end }}
```

Pass 1 reads every YAML file but generates no output. It accumulates all `appendix` dictionaries into `$globalAppendix` using `mergeOverwrite`. Pass 2 reads every YAML file again, but this time it has the complete `$globalAppendix` and can build the final lexicon for each spell (global + chapter local + spell local).

### Consequences

**Benefits:**

- **Spells can reference infrastructure defined in other spells**: A gateway registered in `infrastructure/gateway.yaml` is available to `applications/api-service.yaml` regardless of which chapter is processed first.
- **Complete lexicon available everywhere**: Every spell, in every chapter, sees the same global lexicon. No spell is disadvantaged by processing order.
- **Enables cross-spell dependencies**: Spells can define lexicon entries that other spells consume (e.g., one spell deploys a database and registers it; another spell discovers the database to configure its connection).

**Tradeoffs:**

- **Slightly more complex librarian template code**: The `librarian/templates/runik.yaml` template iterates over all chapters and files twice. The first loop collects data without generating YAML output; the second loop generates the Application manifests. This makes the template harder to read than a single-pass approach.
- **Two iterations over all files**: Helm's `.Files.Get` is called twice per spell file -- once in Pass 1 for appendix collection and once in Pass 2 for Application generation. For large bookracks with hundreds of spells, this doubles the file-reading work. In practice, this has not been a performance concern because Helm template rendering is fast and the files are small YAML documents.

---

## Cross-References

- [architecture.md](architecture.md) -- System overview and data flow
- [librarian.md](librarian.md) -- Detailed librarian internals, including the two-pass implementation
- [rendering-pipeline.md](rendering-pipeline.md) -- End-to-end flow from spell to Kubernetes resources
- [kaster.md](kaster.md) -- Glyph dispatch logic and subchart discovery
- [glyphs.md](glyphs.md) -- Glyph anatomy, type system, and submodule distribution
- [lexicon.md](lexicon.md) -- Runic Indexer internals and selection algorithm
- [merge-system.md](merge-system.md) -- Cascading merge, appendix, localAppendix
- [../usage/runes.md](../usage/runes.md) -- Runes as the replacement for Helm dependencies
- [../usage/lexicon.md](../usage/lexicon.md) -- Registering and discovering infrastructure
- [../usage/spells.md](../usage/spells.md) -- Spell types and detection logic
- [../usage/deploying.md](../usage/deploying.md) -- Librarian execution and ArgoCD bootstrap
