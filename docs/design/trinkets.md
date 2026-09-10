# Trinkets -- Registration, Trigger Mechanism, and Internal Design

This document describes how trinkets work inside Runik Platform at the
implementation level. It covers the registration system, how the Librarian
detects trinket keys in spells, how multi-source ArgoCD Applications are
assembled, and the internal design of each built-in trinket: microspell, tarot,
and covenant.

---

## Registration System

Trinkets are registered in a book's `index.yaml` under the `trinkets:` key.
Each trinket entry declares a **key** (the YAML key the Librarian looks for in
spell files), a **path** (or chart), a **repository**, and a **revision**.

```yaml
# bookrack/my-book/index.yaml
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

### What Each Field Does

| Field | Purpose |
|-------|---------|
| `key` | The top-level YAML key in a spell that activates this trinket. For kaster the key is `glyphs`; for tarot the key is `tarot`. |
| `repository` | The Git repository URL passed to ArgoCD as `repoURL`. |
| `path` | The path within the repository to the trinket's Helm chart. Mutually exclusive with `chart`. |
| `chart` | A Helm chart name from a chart repository. Mutually exclusive with `path`. |
| `revision` | The Git revision or chart version. |

### Chapter-Level Overrides

You can override or extend trinket definitions at the chapter level. The
Librarian merges chapter trinkets on top of book trinkets using
`mergeOverwrite`:

```yaml
# bookrack/my-book/applications/index.yaml
trinkets:
  kaster:
    revision: feature/new-glyph  # override revision for this chapter only
```

You can also override `defaultTrinket` at the chapter level. This changes the
primary chart used for spells that do not specify an explicit `chart:` or
`path:`. For example, to make all spells in a chapter use microspell instead of
summon:

```yaml
# bookrack/my-book/services/index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/microspell.git
  path: .
  revision: upstream
```

---

## Trigger Mechanism

The Librarian detects trinket keys during Pass 2 of its two-pass processing.
The detection logic lives in `librarian/templates/runik.yaml` and follows four
steps.

### Step-by-Step Detection

1. **Spell contains key.** A spell YAML file includes a top-level key that
   matches a registered trinket's `key` field. For example, a spell containing
   `glyphs:` triggers the kaster trinket, and a spell containing `tarot:`
   triggers the tarot trinket.

2. **Librarian iterates registered trinkets.** For each chapter, the Librarian
   builds `$chapterTrinketsByKey` -- a dictionary keyed by the trinket's `key`
   field. It first loads book-level trinkets, then merges chapter-level
   trinkets on top.

3. **If spell has trinket key, add trinket chart as source.** The Librarian
   iterates `$chapterTrinketsByKey` and checks `hasKey $spellDefinition
   $trinketKey`. If the spell has that key, the Librarian appends a new source
   to the ArgoCD Application's `spec.sources` array with the trinket's
   `repository`, `path` (or `chart`), and `revision`.

4. **Pass the value of that key as chart values.** The value under the trinket
   key in the spell is serialized to YAML and passed as `helm.values` for that
   source. The Librarian also injects book context (`spellbook`, `chapter`,
   `lexicon`, `cards`) into the values so that the trinket chart has full
   access to the Runik Platform context.

### Source Code Walkthrough

The following is the relevant template logic from `librarian/templates/runik.yaml`. First, the Librarian builds the trinkets-by-key map:

```go
{{- $chapterTrinketsByKey := dict }}
{{- if $spellbook.trinkets }}
  {{- range $name, $trinket := $spellbook.trinkets }}
    {{- if $trinket.key }}
      {{- $_ := set $chapterTrinketsByKey $trinket.key (deepCopy $trinket) }}
    {{- end }}
  {{- end }}
{{- end }}
```

Then, for each spell, it checks whether the spell definition contains each
trinket key and, if so, adds a new source:

```go
{{- range $trinketKey, $trinket := $chapterTrinketsByKey }}
  {{- if hasKey $spellDefinition $trinketKey }}
    - repoURL: {{ $trinket.repository }}
      {{- if $trinket.chart }}
      chart: {{ $trinket.chart }}
      {{- else }}
      path: {{ $trinket.path }}
      {{- end }}
      targetRevision: {{ $trinket.revision }}
      helm:
        values: |
          {{- if eq $trinketKey "glyphs" }}
          glyphs:
          {{- toYaml (index $spellDefinition $trinketKey) | nindent 12 }}
          {{- else }}
          {{ $trinketKey }}:
          {{- toYaml (index $spellDefinition $trinketKey) | nindent 12 }}
          {{- end }}
          {{- toYaml $cleanSpellbook | nindent 10 }}
          {{- toYaml (dict "chapter" $chapter) | nindent 10 }}
          lexicon:
          {{- toYaml $lexicon | nindent 12 }}
  {{- end }}
{{- end }}
```

### Stripping Trinket Keys from the Default Source

When a spell uses the default trinket (summon), the Librarian strips all
registered trinket keys from the values passed to summon. This prevents summon
from receiving data it does not understand:

```go
{{- range $key, $_ := $chapterTrinketsByKey }}
  {{- $_ := unset $values $key }}
{{- end }}
```

### Resulting ArgoCD Application

A spell that uses both glyphs and tarot produces a multi-source ArgoCD
Application with three sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
spec:
  sources:
    # Source 1: defaultTrinket (summon) -- workload resources
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          name: my-app
          image: ...
          # glyphs: and tarot: keys are stripped

    # Source 2: kaster -- glyph resources (triggered by glyphs: key)
    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          glyphs:
            istio:
              my-vs:
                type: virtualService
                ...

    # Source 3: tarot -- workflow resources (triggered by tarot: key)
    - repoURL: https://github.com/runik-platform/tarot.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          tarot:
            executionMode: dag
            reading:
              cards: ...
```

---

## Microspell Design

Microspell is an opinionated microservice chart that wraps summon with
convention-over-configuration defaults. Its chart lives at
`charts/trinkets/microspell/`.

### Architecture

Microspell is not a standalone rendering engine. It takes a simplified
`microservice:` configuration, transforms it into full summon-compatible values
(replicas, probes, resources, service, autoscaling, security context, etc.),
and renders through summon's template system.

```
Spell YAML
  |
  v
microspell values.yaml (defaults)
  |
  v
microspell templates/base.yaml
  - Transforms microservice config into summon values
  - Generates Istio VirtualService via glyph helpers
  - Generates Vault policy via glyph helpers
  - Generates secrets via glyph helpers
  |
  v
summon templates (inherited as subchart dependency)
  - Deployment/StatefulSet/Job/CronJob
  - Service, ServiceAccount, HPA
  - ConfigMaps, Secrets, PVCs
```

### What Microspell Auto-Configures

When you provide only a `name`, `image`, and `service.enabled: true`,
microspell fills in the following defaults from its `values.yaml`:

| Config | Default |
|--------|---------|
| `workload.type` | `deployment` |
| `workload.replicas` | `2` |
| `serviceAccount.enabled` | `true` |
| `serviceAccount.automount` | `true` |
| `service.type` | `ClusterIP` |
| `autoscaling.minReplicas` | `2` |
| `autoscaling.maxReplicas` | `10` |
| `autoscaling.targetCPUUtilizationPercentage` | `70` |

### Overrides Escape Hatch

Every summon field is available as an override. You write them directly at the
top level of the spell because microspell's `values.yaml` exposes the full
summon surface:

```yaml
name: payment-service
image:
  repository: registry.example.com/payment-service
  tag: v2.1.0

# Microspell-specific
metadata:
  owners: [payments-team]
  serviceLevel: 13
  type: backend

# Standard summon overrides
workload:
  replicas: 5
resources:
  limits:
    cpu: 1000m
    memory: 1Gi
probes:
  liveness:
    type: httpGet
    path: /healthz
    port: 8080
```

### DataStore Integration

Microspell includes a `dataStore.psql` subsystem that can either provision a
managed CloudNativePG cluster or connect to an existing one via the runic
indexer. The behavior is determined by the `selector` field:

- **Empty selector**: creates a new CNPG Cluster resource (managed mode).
- **Non-empty selector**: uses `runicIndexer` to find an existing cluster from
  the lexicon (external mode).

Templates for PostgreSQL live at `charts/trinkets/microspell/templates/psql/`.

---

## Tarot Design

Tarot composes a card-based reading into one self-contained Argo
`WorkflowTemplate`. Its implementation lives in
`charts/trinkets/tarot/templates/_v2.tpl`; Librarian only routes the registered
`tarot` value key and ordinary Runik context.

### Scoped composition

Tarot merges `spellbook.tarot`, `chapter.tarot`, and the spell invocation.
Reusable definitions live under `tarot.cards` at those same scopes. A reading
entry resolves either:

1. `uses: <card-name>` against that scoped catalog; or
2. one inline `container`, `script`, `resource`, or `suspend`.

A reusable card may instead contain one `ref` to an Argo
`WorkflowTemplate` or `ClusterWorkflowTemplate` template. Exactly one
implementation is required after resolution.

Cards publish parameter, artifact, and secret expectations through
`contract.inputs` and `contract.outputs`. Reading entries bind parameters
with `with`, bind artifacts explicitly or from a unique dependency producer,
and order execution with `depends`. Validation rejects unknown cards,
dependencies, inputs, ambiguous artifacts, unbound secrets, and cycles.

### Execution Modes

The `tarot.executionMode` field controls how the Argo WorkflowTemplate is
structured. The logic is in `_v2.tpl`:

| Mode | Argo Construct | Description |
|------|----------------|-------------|
| `dag` | `dag.tasks` | Cards become DAG tasks with dependency edges. Default. |
| `containerSet` | `containerSet.containers` | All cards run as containers in a single pod, sharing volumes. |

`containerSet` is deliberately narrower: every card must resolve to a native
container, dependencies become container dependencies, and data sharing uses
volumes. Template references, artifacts, `when`, and per-card execution
policies remain DAG-only.

### Defaults, extensions, and discovery

The effective scope has one `defaultReading`. A spell without `reading`
uses it, providing the golden-path invocation without turning every
organizational process into a default.

A local or inherited reading can define `extensionPoints` with `after` and
`before` boundaries. `tarot.extend` inserts a validated subgraph and rewires
only those boundaries.

Named readings publish a compact `tarot-reading` reference in the lexicon:
`name` comes from the entry key and `scope`, `namespace`, `template`, and
the public input `contract` are direct fields. A selecting spell renders a
wrapper WorkflowTemplate. Full readings and cards are never stored in the
lexicon.

Event integration uses a second compact entry, `workflow-trigger`. The
`argo-events` Sensor resolves these inversely through `sensorSelector`, then
resolves the target reading through `readingSelector`. Neither Librarian nor
Tarot creates or duplicates Sensor infrastructure.

### Secrets and Resources

Tarot renders workflow-level Kubernetes or Vault secrets, ConfigMaps, and PVCs
through existing glyph helpers. Cards only declare required secret names in
their contract and use native container references; they do not own resource
definitions.

The generic `workflow.template` glyph owns only the Kubernetes resource
envelope. Tarot owns reading composition, while other metaglyphs such as S3 may
reuse the same envelope for their own fixed workflow specs.

### RBAC

When `tarot.rbac.enabled` is true, the chart generates (via `rbac.yaml`):

- A **ServiceAccount** (using `summon.serviceAccount`).
- A **Role** granting access to Argo Workflow resources, pods, secrets,
  configmaps, PVCs, services, and events.
- A **RoleBinding** binding the service account to the role.
- A **ClusterRole** for reading ClusterWorkflowTemplates and node information.
- A **ClusterRoleBinding** for the cluster role.

---

## Covenant

Covenant is not a trinket. It is a path-based application renderer invoked by
Librarian, with one independent instance per IAM realm. See the
[Covenant contract](../../covenant/docs/contracts.md) for its public model
and `make test covenant` for the executable fixture.

---

## Cross-References

- **librarian.md** -- Two-pass processing, how `$chapterTrinketsByKey` is
  built and merged, context passing to trinket sources.
- **summon-internals.md** -- Template structure inherited by microspell;
  workload switching, contentType system, volume and secret helpers reused by
  tarot.
- **kaster.md** -- Glyph dispatch logic; how `glyphs:` data flows from spell
  to kaster to individual glyph templates.
- **lexicon.md** -- Runic indexer used by Tarot reading and event references,
  covenant Keycloak/Vault instance lookups, and microspell DataStore cluster
  selection.
- **merge-system.md** -- Cascading merge rules for `defaultTrinket`,
  `appendix`, `localAppendix`, and chapter-level trinket overrides.
- **glyphs.md** -- Individual glyph types (vault, istio, keycloak,
  cert-manager) invoked by covenant and tarot.
- **creating-trinkets.md** -- Step-by-step guide for building a new trinket
  and registering it in a book.
