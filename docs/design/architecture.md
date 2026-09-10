# Runik Platform Architecture

This document describes the complete architecture of Runik Platform, a Kubernetes
deployment framework built on Helm and ArgoCD. You write simple YAML spells, and
the system generates fully wired ArgoCD Applications that deploy workloads,
infrastructure resources, secrets, networking, and IAM -- all from a single
source of truth.

## Architecture Overview

Start with the diagram. Every component appears here, and the rest of this
document explains each one.

```
  DEVELOPER                 LIBRARIAN                    ARGOCD                   KUBERNETES
  --------                  ---------                    ------                   ----------

  Writes spell YAML
  bookrack/prod/            helm template librarian/
  apps/api.yaml             --set name=prod
       |                         |
       |    PASS 1: Consolidate Appendix
       |    Walks book -> chapters -> spells
       |    Merges all lexicon entries
       |
       |    PASS 2: Generate Applications
       |    For each spell:
       |    1. Merge config (book < chapter < spell)
       |    2. Detect type (image? chart? glyphs?)
       |    3. Strip glyph keys from summon values
       |    4. Generate multi-source Application
       |                         |
       |                    ArgoCD Application
       |                    spec.sources:
       |                     |
       |          +----------+----------+----------+
       |          |          |          |          |
       |       summon     kaster     tarot      runes
       |      (workload) (glyphs)  (events)  (external)
       |          |          |          |          |
       |          +----------+----------+----------+
       |                         |
       |                    Renders Helm charts        kubectl apply
       |                         |                    -------->
       |                                                   |
       |                                              Controllers react:
       |                                              - Deployment -> Pods
       |                                              - VaultSecret -> K8s Secret
       |                                              - VirtualService -> Envoy
```

### How to Read the Diagram

1. You write a spell YAML file and place it in the bookrack directory.
2. The librarian runs as a Helm chart and produces ArgoCD Application manifests.
3. ArgoCD picks up each Application and pulls from its declared sources.
4. Each source is a Helm chart (summon, kaster, tarot, or an external chart).
5. The rendered Kubernetes resources hit the cluster, and controllers reconcile them.

---

## Example First: A Spell End-to-End

Before diving into components, see how a single spell flows through the entire
system.

### You Write This Spell

```yaml
# bookrack/production/services/api-service.yaml
name: api-service
namespace: services

image:
  repository: example/api-service
  tag: "v1.2.3"

workload:
  type: deployment
  replicas: 2

service:
  enabled: true
  ports:
    - port: 8080
      name: http

glyphs:
  vault:
    api-credentials:
      type: secret
      randomKeys:
        - API_KEY
        - JWT_SECRET
  istio:
    api-route:
      type: virtualService
      selector:
        access: external
      hosts:
        - api
      http:
        - match:
            - uri:
                prefix: /api
          route:
            - destination:
                host: api-service
                port:
                  number: 8080
```

### The Librarian Produces This ArgoCD Application

```bash
helm template production librarian/ --set name=production
```

The output is an ArgoCD Application with three sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service
  namespace: argocd
spec:
  project: production
  sources:
    # Source 1: summon (workload chart)
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          name: api-service
          namespace: services
          image:
            repository: example/api-service
            tag: "v1.2.3"
          workload:
            type: deployment
            replicas: 2
          service:
            enabled: true
            ports:
              - port: 8080
                name: http
          spellbook:
            name: production
          chapter:
            name: services
          lexicon:
            external-gateway:
              type: istio-gw
              labels:
                access: external
                default: book
              gateway: istio-system/external-gateway

    # Source 2: kaster (glyph orchestrator)
    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          glyphs:
            vault:
              api-credentials:
                type: secret
                randomKeys:
                  - API_KEY
                  - JWT_SECRET
            istio:
              api-route:
                type: virtualService
                selector:
                  access: external
                hosts:
                  - api
                http:
                  - match:
                      - uri:
                          prefix: /api
                    route:
                      - destination:
                          host: api-service
                          port:
                            number: 8080
          spellbook:
            name: production
          chapter:
            name: services
          lexicon:
            external-gateway:
              type: istio-gw
              labels:
                access: external
                default: book
              gateway: istio-system/external-gateway

  destination:
    server: https://kubernetes.default.svc
    namespace: services
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
```

### ArgoCD Renders and Applies

ArgoCD pulls each source, runs `helm template`, and applies the result:

- **summon** produces: Deployment, Service, ServiceAccount
- **kaster** produces: VaultSecret (api-credentials), VirtualService (api-route)

Kubernetes controllers then reconcile:

- Deployment controller creates Pods
- Vault operator reads VaultSecret and creates a Kubernetes Secret
- Istio pilot reads VirtualService and configures Envoy sidecars

---

## Data Flow

The complete data flow from developer input to running workload:

```
spell YAML
    |
    v
librarian (helm template)
    |
    v
ArgoCD Application YAML
    |
    v
ArgoCD pulls sources (summon, kaster, tarot, runes)
    |
    v
helm template per source
    |
    v
Kubernetes resources (Deployment, Service, VaultSecret, VirtualService, ...)
    |
    v
Controllers react (kubelet, vault-operator, istio-pilot, cert-manager, ...)
```

### Data Flow Details

| Stage | Input | Output | Mechanism |
|-------|-------|--------|-----------|
| Spell authoring | Developer intent | YAML file in bookrack | Manual edit |
| Pass 1: Appendix consolidation | Book, chapters, spells | Merged lexicon dictionary | `mergeOverwrite` across all files |
| Pass 2: Application generation | Spell + merged config | ArgoCD Application YAML | Go template in `librarian/templates/runik.yaml` |
| Source detection | Spell keys (`glyphs`, `tarot`, `runes`) | Multi-source `spec.sources[]` | Key presence check per trinket |
| Value stripping | Spell values | Summon values without glyph keys | `unset` for each trinket key |
| ArgoCD sync | Application YAML | Rendered K8s manifests | ArgoCD pulls repo, runs `helm template` |
| Controller reconciliation | K8s manifests | Running workloads and infrastructure | Kubernetes control loop |

---

## Technology Stack

| Technology | Role | Why |
|------------|------|-----|
| Kubernetes | Target platform | Industry standard container orchestration |
| Helm | Templating engine | Go templates with values merging, chart packaging |
| ArgoCD | GitOps deployment | Declarative, multi-source Application CRD |
| Go Templates | Template language | Native to Helm, rich standard library |
| YAML | Configuration format | Human-readable, nests well, merges cleanly |

### Key Technical Decisions

- **Helm as a template engine, not a package manager.** The librarian uses
  `helm template` to generate ArgoCD Applications. ArgoCD then uses Helm again
  to render each source chart. This two-layer approach means the librarian never
  installs anything directly.

- **ArgoCD multi-source Applications.** A single ArgoCD Application can pull from
  multiple Helm charts simultaneously. The librarian exploits this to combine
  summon (workloads), kaster (infrastructure glyphs), tarot (event workflows),
  and runes (external charts) into one Application per spell.

- **Copied glyphs, not Helm dependencies.** Glyph templates live in
  `charts/glyphs/` and are synced into `charts/kaster/templates/` and
  `charts/summon/templates/`. This avoids Helm dependency resolution overhead
  and lets glyphs share a flat template namespace.

---

## Components and Relationships

| Component | Purpose | Location | Description |
|-----------|---------|----------|-------------|
| Bookrack | Config storage | `bookrack/` | Hierarchical YAML config: books, chapters, spells |
| Librarian | Apps-of-Apps generator | `librarian/` | Two-pass Helm chart that reads bookrack and emits ArgoCD Applications |
| Summon | Workload chart | `charts/summon/` | Renders Deployments, StatefulSets, Jobs, CronJobs, DaemonSets, Services, ConfigMaps, Secrets |
| Kaster | Glyph orchestrator | `charts/kaster/` | Dispatches glyph definitions to the correct glyph template |
| Glyphs | Infrastructure templates | `charts/glyphs/` | Reusable templates for Vault, Istio, CertManager, PostgreSQL, AWS, GCP, Crossplane, and more |
| Trinkets | Specialized charts | `charts/trinkets/` | Charts with specific purposes: tarot (workflows), microspell (opinionated microservices) |
| Covenant | IAM renderer | `covenant/` | Renders one complete organization/realm from its IAM book and selected application contracts inside one Argo CD Application |
| Lexicon | Infrastructure registry | Appendix in bookrack files | Dictionary of named infrastructure resources (gateways, clusters, issuers, databases) |
| Runic Indexer | Lexicon query engine | `charts/glyphs/runic-system/` | Go template function that queries the lexicon by type and label selectors |
| Runes | External chart sources | Inline in spell YAML | Additional ArgoCD sources pointing to third-party Helm charts |

### Component Interaction Map

```
bookrack/
  |
  |  (reads)
  v
librarian/                    ArgoCD
  |                             |
  |  (generates)                |  (syncs)
  v                             v
ArgoCD Application  -------> charts/summon/     --> Deployment, Service, SA, ...
  spec.sources:     -------> charts/kaster/     --> VaultSecret, VirtualService, ...
                    -------> charts/trinkets/   --> Argo Workflows, Keycloak realms, ...
                    -------> (external charts)  --> Prometheus, Redis, ...
                                |
                                |  (uses templates from)
                                v
                          charts/glyphs/
                            ├── vault/
                            ├── istio/
                            ├── cert-manager/
                            ├── postgresql/
                            ├── aws/
                            ├── gcp/
                            ├── crossplane/
                            ├── external-secrets/
                            ├── s3/
                            ├── argo-events/
                            ├── keycloak/
                            ├── free-form/
                            ├── common/
                            ├── summon/
                            └── runic-system/
```

---

## Bookrack: Configuration Hierarchy

The bookrack stores all deployment configuration in a three-level hierarchy.

### Hierarchy

```
bookrack/
└── {book}/                  # e.g., production, staging
    ├── index.yaml           # Book-level config: trinkets, defaultTrinket, appParams
    ├── {chapter}/           # e.g., infrastructure, services, data
    │   ├── index.yaml       # Chapter-level overrides: appParams, trinkets, localAppendix
    │   └── {spell}.yaml     # Individual spell files
    └── {chapter}/
        ├── index.yaml
        └── {spell}.yaml
```

### Example Book Index

```yaml
# bookrack/production/index.yaml
name: production
description: "Production environment"

chapters:
  - infrastructure
  - services

defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream

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

appParams:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Configuration Merge Order

Configuration cascades with later values overriding earlier ones:

```
book.appParams  <  chapter.appParams  <  spell.appParams
book.trinkets   <  chapter.trinkets
book.defaultTrinket  <  chapter.defaultTrinket
```

For the appendix (lexicon and cards), merging works differently:

```
Pass 1 collects:   book.appendix + all chapter.appendix + all spell.appendix
Pass 2 applies:    globalAppendix < chapter.localAppendix < spell.localAppendix
```

---

## Librarian: Two-Pass Processing

The librarian (`librarian/templates/runik.yaml`) is the core engine. It reads
the entire bookrack in two passes and generates one ArgoCD Application per spell.

### Pass 1: Appendix Consolidation

The first pass walks every chapter and every spell, collecting all `appendix`
entries into a single `$globalAppendix` dictionary:

```go
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}
{{- range $chapterName := $spellbook.chapters }}
  {{- /* merge chapter.appendix */}}
  {{- /* merge each spell.appendix */}}
{{- end }}
```

This means a gateway defined in `infrastructure/gw-external.yaml` becomes
available to every spell in every chapter via the lexicon.

### Pass 2: Application Generation

The second pass iterates chapters and spells again. For each spell, it:

1. **Merges appParams**: book defaults, then chapter overrides, then spell overrides.
2. **Builds trinkets-by-key**: collects all registered trinkets (e.g., `glyphs`, `tarot`) and their source coordinates.
3. **Detects source type**: checks whether the spell has `chart`/`path` (external chart) or uses the `defaultTrinket` (summon).
4. **Strips trinket keys**: removes keys like `glyphs` and `tarot` from the values passed to summon, so summon only receives workload config.
5. **Generates multi-source Application**: emits one ArgoCD Application with a source for each detected trinket, plus runes.

### Source Detection Logic

```
if spell has chart/path:
    Source 1 = custom chart (explicit repository/chart/path)
else:
    Source 1 = defaultTrinket (summon)

for each trinket key (glyphs, tarot, ...):
    if spell has that key:
        Add source for that trinket's chart

for each rune in spell.runes:
    if rune has chart/path:
        Add source for that rune
    else:
        Add source using defaultTrinket (summon) with rune values
```

---

## Summon: Workload Chart

Summon (`charts/summon/`) renders standard Kubernetes workloads. You pass it
values like `image`, `workload`, `service`, `envs`, `secrets`, and `configMaps`,
and it produces the corresponding resources.

### Supported Workload Types

| Type | Resource | Use Case |
|------|----------|----------|
| `deployment` | Deployment + ReplicaSet | Stateless services (default) |
| `statefulset` | StatefulSet | Databases, caches with stable identity |
| `job` | Job | One-time tasks, migrations |
| `cronjob` | CronJob | Scheduled tasks |
| `daemonset` | DaemonSet | Node-level agents |

### Example: Minimal Summon Spell

```yaml
name: my-api
image:
  repository: nginx
  tag: alpine
service:
  enabled: true
  ports:
    - port: 80
      name: http
```

This produces: Deployment, Service, and ServiceAccount.

---

## Kaster: Glyph Orchestrator

Kaster (`charts/kaster/`) receives the `glyphs` dictionary from a spell and
dispatches each entry to the appropriate glyph template. It does not contain
business logic itself -- it routes glyph definitions to the templates in
`charts/glyphs/`.

### Example: Glyphs in a Spell

```yaml
glyphs:
  vault:
    db-credentials:
      type: secret
      secretType: kubernetes.io/basic-auth
      randomKeys:
        - password
  istio:
    my-route:
      type: virtualService
      hosts:
        - api
      http:
        - match:
            - uri:
                prefix: /
          route:
            - destination:
                host: my-api
                port:
                  number: 80
```

Kaster passes `vault.db-credentials` to the vault glyph templates and
`istio.my-route` to the istio glyph templates.

---

## Glyphs: Infrastructure Templates

Glyphs are Go template files in `charts/glyphs/` that produce Kubernetes
resources for specific infrastructure concerns. Each glyph directory handles
one technology domain.

### Available Glyph Domains

| Domain | Directory | Resources Produced |
|--------|-----------|-------------------|
| Vault | `charts/glyphs/vault/` | VaultSecret, VaultPolicy, SecretEngineMount, DatabaseEngine |
| Istio | `charts/glyphs/istio/` | Gateway, VirtualService |
| Cert-Manager | `charts/glyphs/cert-manager/` | Certificate, DNSEndpoint |
| PostgreSQL | `charts/glyphs/postgresql/` | PostgreSQL CloudNativePG resources |
| AWS | `charts/glyphs/aws/` | IAM roles/policies, RDS instances, S3 buckets, ACK controllers |
| GCP | `charts/glyphs/gcp/` | Service accounts, KMS keys, networks, GKE clusters, VMs, DNS |
| Crossplane | `charts/glyphs/crossplane/` | Crossplane Provider resources |
| External Secrets | `charts/glyphs/external-secrets/` | ExternalSecret (AWS, GCP backends) |
| S3 | `charts/glyphs/s3/` | S3/SeaweedFS bucket provisioning |
| Argo Events | `charts/glyphs/argo-events/` | EventSource, Sensor |
| Keycloak | `charts/glyphs/keycloak/` | Realm, Client, User, Group, IDP, AuthFlow |
| FreeForm | `charts/glyphs/free-form/` | Arbitrary YAML resources |
| Common | `charts/glyphs/common/` | Shared helpers: names, labels, annotations, validation |
| Summon | `charts/glyphs/summon/` | Service, storage, workload helpers used by summon chart |
| Runic System | `charts/glyphs/runic-system/` | Runic Indexer template function |

---

## Trinkets: Specialized Charts

Trinkets are Helm charts registered in the book index under the `trinkets` key.
The librarian detects when a spell uses a trinket key and adds the trinket chart
as an additional ArgoCD source.

### Trinket Registration

```yaml
# bookrack/{book}/index.yaml
trinkets:
  kaster:
    key: glyphs          # Spell key that triggers this trinket
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: upstream
  tarot:
    key: tarot
    repository: https://github.com/runik-platform/tarot.git
    path: .
    revision: upstream
```

### Built-in Trinkets

| Trinket | Key | Chart | Purpose |
|---------|-----|-------|---------|
| Kaster | `glyphs` | `charts/kaster/` | Routes glyph definitions to infrastructure templates |
| Tarot | `tarot` | `charts/trinkets/tarot/` | Reusable process composition (Argo WorkflowTemplates) |
| Microspell | N/A | `charts/trinkets/microspell/` | Opinionated microservice chart with built-in Vault/Istio integration |

### Tarot Example

```yaml
# bookrack/production/services/my-app.yaml
name: my-app
image:
  repository: myorg/app
  tag: v1.0

tarot:
  cards:
    build:
      container:
        image: golang:1.24
        command: ["go", "build", "./..."]
    test:
      container:
        image: golang:1.24
        command: ["go", "test", "./..."]
  reading:
    cards:
      compile:
        uses: build
      verify:
        uses: test
        depends: [compile]
```

This creates a third ArgoCD source pointing to the Tarot chart, which renders a
self-contained Argo WorkflowTemplate and its execution RBAC.

---

## Runes: External Chart Sources

Runes let you attach additional Helm chart sources to a spell. Each rune becomes
an extra entry in `spec.sources[]` of the ArgoCD Application.

### Rune with Explicit Chart

```yaml
name: my-app
image:
  repository: myorg/app
  tag: v1.0

runes:
  - repository: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    revision: 51.3.0
    values:
      prometheus:
        enabled: true
```

### Rune Fallback (No Chart Specified)

When a rune has only `values` and no `chart`/`path`, the librarian uses the
`defaultTrinket` (summon) as the source:

```yaml
name: my-app
image:
  repository: myorg/app
  tag: v1.0

runes:
  - values:
      workload:
        type: job
      image:
        repository: alpine
        tag: latest
      command: ["echo", "migration complete"]
```

This produces two summon sources: one for the main deployment and one for the
migration job.

---

## Lexicon and Runic Indexer

The lexicon is a shared dictionary of infrastructure resources. Spells register
resources into the lexicon via the `appendix` field, and other spells discover
those resources via label-based queries.

### Registering Infrastructure

```yaml
# bookrack/production/infrastructure/gw-external.yaml
name: external-gateway
repository: 'https://github.com/istio/istio.git'
path: manifests/charts/gateways/istio-ingress
revision: 1.23.0

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

### Querying the Lexicon

Glyphs use the runic indexer to find infrastructure by type and labels:

```go
{{- $gateways := get (include "runic-system.runic-indexer"
    (list $lexicon $selector "istio-gw" $chapter)
    | fromJson) "results" }}
```

### Selection Priority

The runic indexer follows this priority when resolving queries:

| Priority | Condition | Behavior |
|----------|-----------|----------|
| 1 | All selectors match labels (AND logic) | Return exact matches |
| 2 | No exact match, entry has `default: book` | Return book-level default |
| 3 | No exact match or book default, entry has `default: chapter` and same chapter | Return chapter-level default |

### Example: Spell Uses Lexicon via Selector

```yaml
# This spell references the external gateway without knowing its name
glyphs:
  istio:
    my-route:
      type: virtualService
      selector:
        access: external    # Matches the gateway registered above
      hosts:
        - api
```

The runic indexer finds `external-gateway` because its labels include
`access: external`, and passes the gateway details to the istio glyph template.

---

## Covenant: Identity and Access Management

Covenant renders one IAM book and selected application contracts into one realm
and Argo CD Application. The book owns identities and RBAC; application spells
own role targets and per-realm clients. Provider resources stay separate from
authorization and infrastructure providers resolve through Lexicon. Covenant
does not own application provisioning. A second realm is an independent
Covenant instance.

See [the Covenant contract](../../covenant/docs/contracts.md) for the
layout, defaults, and examples.

---

## Project Structure

The complete directory layout of the repository:

```
runik/
├── bookrack/                           # Configuration storage (all books)
│   ├── {book}/
│   │   ├── index.yaml                  # Book definition: chapters, trinkets, appParams
│   │   └── {chapter}/
│   │       ├── index.yaml              # Chapter overrides
│   │       └── {spell}.yaml            # Individual spell files
│   ├── example-book/                    # Realistic deployable integration fixture
│   └── covenant-example/               # Direct Covenant IAM input
│
├── librarian/                          # Apps-of-Apps generator
│   ├── Chart.yaml                      # Helm chart metadata (v1.2.4)
│   ├── values.yaml                     # Default appParams and sync policies
│   └── templates/
│       ├── runik.yaml                  # Core engine: two-pass processing
│       └── project.yaml               # ArgoCD AppProject generation
│
├── charts/
│   ├── summon/                         # Workload chart
│   │   ├── Chart.yaml                  # v1.2.5
│   │   ├── values.yaml                 # All workload fields documented
│   │   ├── templates/                  # Workload rendering templates
│   │   └── examples/                   # Usage examples
│   │
│   ├── kaster/                         # Glyph orchestrator
│   │   ├── Chart.yaml                  # v1.4.4
│   │   ├── values.yaml                 # Glyph input schema
│   │   ├── templates/                  # Dispatch logic + glyph templates
│   │   └── examples/                   # Glyph usage examples
│   │
│   ├── glyphs/                         # Infrastructure template library
│   │   ├── vault/                      # Vault secrets, policies, engines
│   │   ├── istio/                      # Gateways, VirtualServices
│   │   ├── cert-manager/                # Certificates, DNS endpoints
│   │   ├── postgresql/                 # CloudNativePG databases
│   │   ├── aws/                        # IAM, RDS, S3, ACK controllers
│   │   ├── gcp/                        # IAM, KMS, GKE, networking, DNS
│   │   ├── crossplane/                 # Crossplane providers
│   │   ├── external-secrets/           # ExternalSecret resources
│   │   ├── s3/                         # S3-compatible bucket provisioning
│   │   ├── argo-events/                # EventSource, Sensor
│   │   ├── keycloak/                   # Full Keycloak CRD support
│   │   ├── free-form/                   # Arbitrary YAML passthrough
│   │   ├── common/                     # Shared helpers (names, labels)
│   │   ├── summon/                     # Workload sub-templates
│   │   └── runic-system/              # Runic Indexer query engine
│   │
│   └── trinkets/                       # Specialized charts
│       ├── tarot/                      # Workflow composition (Argo Workflows)
│       │   ├── Chart.yaml             # v0.1.0
│       │   └── examples/
│       └── microspell/                 # Opinionated microservice chart
│           ├── Chart.yaml             # v0.0.1
│           └── examples/
│
├── covenant/                           # IAM system
│   ├── Chart.yaml                      # v0.7.0
│   ├── values.yaml                     # single-instance chart defaults
│   ├── docs/contracts.md               # Canonical contracts
│   └── templates/                      # Compiler + deterministic renderer
│       ├── covenant.yaml
│       ├── _helpers.tpl
│       ├── _scan.tpl
│       ├── _compiler.tpl
│       └── _metaglyphs.tpl
│
├── docs/                               # Documentation
│   ├── usage/                          # User-facing guides
│   └── design/                         # Architecture and internals
│
└── LICENSE                             # GNU AGPL v3
```

---

## Deploying the System

### Generate Applications for a Book

```bash
helm template production librarian/ --set name=production
```

### Preview What the Librarian Produces

```bash
helm template production librarian/ --set name=production | kubectl apply --dry-run=client -f -
```

### Apply to ArgoCD

```bash
helm template production librarian/ --set name=production | kubectl apply -f -
```

ArgoCD then takes over, syncing each Application by pulling its declared sources,
rendering them, and applying the results to the cluster.

---

## Cross-References

The following documents provide deeper coverage of each topic:

| Topic | Document |
|-------|----------|
| Bookrack hierarchy and merging | [usage/bookrack.md](../usage/bookrack.md) |
| Spell types and anatomy | [usage/spells.md](../usage/spells.md) |
| Librarian two-pass internals | [design/librarian.md](librarian.md) |
| Summon workload internals | [design/summon-internals.md](summon-internals.md) |
| Kaster dispatch logic | [design/kaster.md](kaster.md) |
| Lexicon and Runic Indexer | [design/lexicon.md](lexicon.md) |
| Glyph anatomy and type system | [design/glyphs.md](glyphs.md) |
| Trinket registration and design | [design/trinkets.md](trinkets.md) |
| Cascading merge system | [design/merge-system.md](merge-system.md) |
| End-to-end rendering pipeline | [design/rendering-pipeline.md](rendering-pipeline.md) |
| Architectural decisions | [design/architectural-decisions.md](architectural-decisions.md) |
| Creating custom glyphs | [design/creating-glyphs.md](creating-glyphs.md) |
| Creating custom trinkets | [design/creating-trinkets.md](creating-trinkets.md) |
