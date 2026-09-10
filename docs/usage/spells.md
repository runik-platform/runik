# Spells

## What is a Spell?

A **spell** is a single YAML file in bookrack that declares what you want deployed. It is the fundamental unit of configuration in Runik Platform.

**Location**: `bookrack/<book>/<chapter>/<spell-name>.yaml`

The Librarian reads each spell and generates an ArgoCD Application with one or more chart sources.

## Minimal Spell

```yaml
name: my-app
image: myorg/app:v1.0
```

Two lines. Summon handles all defaults -- creates a Deployment with one replica and the specified image.

## Common Spell Fields

```yaml
name: my-app              # Required: resource name
namespace: applications   # Optional: K8s namespace (defaults to name)
namePrefix: prod-         # Optional: prefix added to name
nameSuffix: -v2           # Optional: suffix added to name

appParams:                # Optional: ArgoCD Application configuration
  annotations:
    argocd.argoproj.io/sync-wave: "10"
  disableAutoSync: false

clusterSelector:          # Optional: target cluster via lexicon
  region: us-west
  environment: production

appendix:                 # Optional: register in book lexicon
  lexicon:
    my-resource:
      type: custom
      labels:
        foo: bar

localAppendix:            # Optional: chapter-only lexicon entry
  lexicon:
    chapter-resource:
      type: custom
```

## Spell Types

The Librarian determines which charts to use based on what keys are present in the spell. The core rule: when a spell has no `chart:` or `path:`, the defaultTrinket (summon) always runs. If a spell has `chart:` or `path:`, it must also have `repository:` and `revision:`.

| Type | Spell Content | Sources Generated |
|------|---------------|-------------------|
| 1. Summon | No `chart:`, no `path:` (e.g. `image:` only) | defaultTrinket |
| 2. Summon + inline glyphs | No `chart:`, no `path:` + top-level glyph keys (`vault:`/`istio:`/etc.) | defaultTrinket only (glyphs render inside summon) |
| 3. External chart | `chart:` + `repository:` + `revision:` | external chart |
| 4. External chart + Glyphs | `chart:` + `repository:` + `revision:` + `glyphs:` | external chart + kaster |
| 5. Infrastructure only | No `chart:`, no `path:` + top-level glyph keys + `workload.enabled: false` | defaultTrinket only (glyphs render inside summon) |
| 6. With runes | Any + `runes:` | + rune sources |
| 7. Workflow composition | Any + `tarot:` | + tarot source |

### Type 1: Summon (defaultTrinket)

When a spell has no `chart:` and no `path:`, the book's defaultTrinket (typically summon) is used as the primary source.

```yaml
name: api-service
namespace: applications
image: myorg/api:v1.2.3

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
      name: http

probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
```

**Generates**: ArgoCD Application with summon source -> Deployment, Service, ServiceAccount.

### Type 2: Summon + inline glyphs (image: + top-level glyph keys)

When a spell has no `chart:` or `path:`, top-level glyph keys (`vault:`, `istio:`, `cert-manager:`, etc.) remain in the values passed to summon. Summon's internal dispatcher matches those keys to its bundled glyph subcharts and renders the resources inside the same source. Librarian does not create a kaster source unless the spell contains the literal `glyphs:` trinket key.

```yaml
name: api-service
image: myorg/api:v1.0

service:
  enabled: true

vault:
  db-creds:
    type: secret
    path: secret/data/production/db

istio:
  route:
    type: virtualService
    selector:
      access: external
    hosts:
      - api.example.com

cert-manager:
  tls:
    type: certificate
    dnsNames:
      - api.example.com
```

**Generates**: one ArgoCD Application with one summon source. Summon renders the Deployment and Service plus the VaultSecret, VirtualService, and Certificate through its internal glyph dispatcher.

### Type 3: External Chart (chart: + repository:)

Use any Helm chart from any repository.

```yaml
name: nginx
namespace: web
repository: https://charts.bitnami.com/bitnami
chart: nginx
revision: 18.2.6

values:
  replicaCount: 2
  image:
    tag: 1.25.0
  service:
    type: LoadBalancer
```

**Generates**: ArgoCD Application with bitnami/nginx as source.

### Type 4: External Chart + Glyphs (chart: + glyphs:)

For external charts, use the `glyphs:` wrapper to prevent passing unknown keys to the external chart.

```yaml
name: nginx
namespace: web
repository: https://charts.bitnami.com/bitnami
chart: nginx
revision: 18.2.6

values:
  replicaCount: 2

glyphs:
  istio:
    route:
      type: virtualService
      selector:
        access: external
      hosts:
        - nginx.example.com
  cert-manager:
    tls:
      type: certificate
      dnsNames:
        - nginx.example.com
```

**Generates**: ArgoCD Application with 2 sources:
- Source 1 (bitnami/nginx): Deployment, Service
- Source 2 (kaster): VirtualService, Certificate

**Why the `glyphs:` wrapper?** External charts do not understand `istio:` or `cert-manager:` keys. The wrapper isolates infrastructure config from the external chart values.

### Type 5: Infrastructure Only (glyph keys + workload disabled)

When a spell has no `chart:` and no `path:`, the defaultTrinket (summon) always runs. To create a spell with only infrastructure glyphs and no workload, disable the workload explicitly with `workload.enabled: false`:

```yaml
name: tls-certificates
namespace: infrastructure

workload:
  enabled: false

cert-manager:
  wildcard-cert:
    type: certificate
    dnsNames:
      - "*.example.com"
      - example.com

  api-cert:
    type: certificate
    dnsNames:
      - api.example.com

istio:
  external-gateway:
    type: istio-gw
    hosts:
      - "*.example.com"
    tls:
      enabled: true
```

**Generates**: one ArgoCD Application with one summon source. Summon produces no Deployment because `workload.enabled: false`, but its internal glyph dispatcher still renders the two Certificates and the Gateway. No kaster source is emitted.

### Type 6: With Runes (runes:)

Any spell type can include `runes:` to add external Helm charts as additional ArgoCD sources.

```yaml
name: app-with-monitoring
image: myorg/app:v1.0

service:
  enabled: true

vault:
  secret:
    path: secret/data/app

runes:
  - repository: https://prometheus-community.github.io/helm-charts
    chart: prometheus
    revision: 15.0.0
    values:
      server:
        enabled: true

  - repository: https://grafana.github.io/helm-charts
    chart: grafana
    revision: 6.50.0
```

**Generates**: ArgoCD Application with 4 sources: summon + kaster + prometheus + grafana.

### Type 7: Workflow composition (tarot:)

Spells with `tarot:` trigger the Tarot trinket, which renders a self-contained
Argo `WorkflowTemplate`. A reading composes reusable or inline cards with
explicit dependencies.

```yaml
name: ci-pipeline
namespace: automation

tarot:
  executionMode: dag
  cards:
    clone-repository:
      container:
        image: alpine/git:latest
        command: ["git", "clone", "https://example.com/repo.git", "/workspace"]
    run-tests:
      container:
        image: golang:1.24
        command: ["go", "test", "./..."]
  reading:
    cards:
      checkout:
        uses: clone-repository
      test:
        uses: run-tests
        depends: [checkout]
```

**Generates**: an ArgoCD Application with the normal primary source and a Tarot
source containing the WorkflowTemplate and its execution RBAC.

Cards inherited from book or chapter scope live under `tarot.cards`; they are
not published in `appendix`. Named readings may publish a small
`type: tarot-reading` reference in `appendix.lexicon` for selector-based
reuse.

Event-driven triggering remains in the separate `argo-events` glyph. Workflow
owners publish `workflow-trigger` references that select the infrastructure
Sensor and the target reading. The Sensor discovers them during render; Tarot
only grants its ServiceAccount through `tarot.rbac.triggerServiceAccounts`.

## Spell Naming

```yaml
name: api-service                    # -> api-service
namePrefix: prod-                    # -> prod-api-service
nameSuffix: -v2                      # -> prod-api-service-v2
```

Name prefix and suffix can also be set at the book or chapter level. All spells in that scope inherit them.

## Spell Merging

Spells inherit configuration from their book and chapter:

```
Book values (index.yaml)
  |  merge (book < chapter)
Chapter values (chapter/index.yaml)
  |  merge (chapter < spell)
Spell values (spell.yaml)
  |
Final values passed to charts
```

See [bookrack.md](bookrack.md) for a concrete merge example.

## Best Practices

**Use defaults**:
```yaml
# Good: minimal, clear
name: api
image: myorg/api:v1.0
service:
  enabled: true

# Avoid: over-specified with defaults
name: api
image:
  repository: myorg/api
  tag: v1.0
  pullPolicy: IfNotPresent    # Already the default
workload:
  type: deployment             # Already the default
  replicas: 1
```

**Register infrastructure in lexicon**:
```yaml
name: external-gateway

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      gateway: infrastructure/external-gateway
      labels:
        access: external
        default: book
```

**Use meaningful names**:
```yaml
# Good
name: user-authentication-api
name: nightly-backup-job

# Avoid
name: api
name: job1
```

## Cross-References

- [summon.md](summon.md) -- All workload configuration fields
- [glyphs.md](glyphs.md) -- Available glyph types and configuration
- [runes.md](runes.md) -- How to add external charts
- [trinkets.md](trinkets.md) -- Microspell, Tarot, Covenant
- [bookrack.md](bookrack.md) -- Configuration hierarchy and merging
