# Runes

## Quick Example

```yaml
name: my-app
image: myorg/app:v1.0

service:
  enabled: true

runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
    values:
      auth:
        enabled: false
```

This spell deploys your application via summon and adds a Redis instance from the Bitnami Helm chart -- both managed as sources in a single ArgoCD Application.

## What Are Runes?

A **rune** is an external Helm chart (or Git-based chart) added as an additional ArgoCD source alongside your primary spell. When you add `runes:` to any spell, the Librarian appends each rune as a separate source entry in the generated ArgoCD Application manifest.

The ArgoCD Application ends up with multiple sources:

```
Source 1: Your primary chart (summon, external chart, or kaster)
Source 2: Rune #1 (e.g., redis)
Source 3: Rune #2 (e.g., postgresql)
...
```

Each source syncs independently within the same Application, giving you fine-grained control over what gets deployed alongside your workload.

## Why Runes Instead of Helm Dependencies

Traditional Helm uses `Chart.yaml` dependencies with `helm dep update` to bundle sub-charts. This approach has several drawbacks in a GitOps workflow:

| Problem with Helm Dependencies | How Runes Solve It |
|---|---|
| `.tgz` archives committed to Git | No archives -- ArgoCD fetches charts directly from their repositories |
| `helm dep update` required before every deploy | No build step -- the Librarian generates ArgoCD sources declaratively |
| All sub-charts share a single `values.yaml` | Each rune has its own isolated `values:` block |
| Upgrading a dependency means re-downloading and re-committing | Change `revision:` in YAML -- ArgoCD pulls the new version |
| No per-dependency sync control | Each rune is a separate ArgoCD source with independent sync |
| Sub-charts must be Helm-compatible with the parent | Runes are standalone charts -- no compatibility constraints |

In short, runes give you the composability of Helm dependencies with the declarative, Git-native workflow that ArgoCD expects.

## Basic Rune Configuration

Every rune needs three fields to point at an external Helm chart: `repository`, `chart`, and `revision`. You can optionally pass `values` to configure the chart.

```yaml
name: my-app
image: myorg/app:v1.0

runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: postgresql
    revision: 12.8.0
    values:
      auth:
        postgresPassword: changeme
        database: myapp
      primary:
        persistence:
          enabled: true
          size: 10Gi
```

### Rune Fields Reference

| Field | Required | Description |
|---|---|---|
| `repository` | Yes (for external charts) | Helm repository URL or Git repository URL |
| `chart` | Yes (for Helm repos) | Chart name within the repository |
| `path` | Yes (for Git repos) | Path to the chart within the Git repository |
| `revision` | Yes | Chart version (for Helm repos) or branch/tag/commit (for Git repos) |
| `values` | No | Helm values passed to the chart |
| `name` | No | Human-readable identifier for the rune |
| `appParams` | No | ArgoCD Application parameters specific to this rune |

## Rune with Custom Values

You can pass any values the target chart supports. Here is a comprehensive example deploying a payment service with Redis and PostgreSQL runes:

```yaml
name: payment-service
namespace: applications

image:
  repository: example-registry/payment-service
  tag: v2.1.0

service:
  enabled: true
  ports:
    - port: 80
      name: http
    - port: 8080
      name: admin

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

envs:
  SERVICE_NAME: payment-service
  ENVIRONMENT: production
  LOG_LEVEL: info

runes:
  - name: redis-cache
    repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 17.11.3
    values:
      auth:
        enabled: false
      master:
        persistence:
          enabled: false

  - name: postgresql-db
    repository: https://charts.bitnami.com/bitnami
    chart: postgresql
    revision: 12.8.0
    values:
      auth:
        postgresPassword: dev-password-123
        database: payments
      primary:
        persistence:
          enabled: true
          size: 20Gi
```

**Generates**: An ArgoCD Application with 3 sources -- summon (Deployment, Service, HPA) + Redis chart + PostgreSQL chart.

## Rune with appParams

Each rune can carry its own `appParams` to control ArgoCD behavior. Rune-level `appParams` merge into the spell-level `appParams`, so a rune can influence the entire Application's sync policy.

```yaml
name: data-pipeline
namespace: applications
image: myorg/pipeline:v1.0

runes:
  - name: kafka
    repository: https://charts.bitnami.com/bitnami
    chart: kafka
    revision: 26.0.0
    appParams:
      disableAutoSync: true
      ignoreDifferences:
        - group: apps
          kind: StatefulSet
          jsonPointers:
            - /spec/replicas
      syncPolicy:
        syncOptions:
          - ServerSideApply=true
      annotations:
        argocd.argoproj.io/sync-wave: "5"
    values:
      controller:
        replicaCount: 3
      listeners:
        client:
          protocol: PLAINTEXT
```

### appParams Fields for Runes

| Field | Effect |
|---|---|
| `disableAutoSync` | Disables automated sync for the entire Application |
| `ignoreDifferences` | Adds ignore-difference rules to the Application (accumulated across all runes) |
| `syncPolicy` | Merges into the Application sync policy |
| `annotations` | Merges into the Application metadata annotations |
| `skipCrds` | Skips CRD installation for this rune's source |
| `noHelm` | Disables the Helm values block for this rune (plain manifest source) |
| `noOverite` | Prevents this rune's appParams from merging into the spell-level appParams |

Note: `ignoreDifferences` from all runes are concatenated (not overwritten). All other `appParams` fields merge, with later runes overriding earlier ones unless `noOverite` is set.

## Multiple Runes

You can attach as many runes as you need. Here is a production-grade observability stack deployed alongside a main application:

```yaml
name: platform-services
namespace: monitoring

repository: https://prometheus-community.github.io/helm-charts
chart: kube-prometheus-stack
revision: 51.3.0

appParams:
  disableAutoSync: true
  annotations:
    argocd.argoproj.io/sync-wave: "-10"

values:
  prometheus:
    enabled: true
    prometheusSpec:
      retention: 30d
  grafana:
    enabled: true
  alertmanager:
    enabled: true

runes:
  - name: postgresql
    repository: https://charts.bitnami.com/bitnami
    chart: postgresql
    revision: 12.8.0
    values:
      auth:
        database: grafana
      primary:
        persistence:
          size: 10Gi

  - name: rabbitmq
    repository: https://charts.bitnami.com/bitnami
    chart: rabbitmq
    revision: 12.0.0
    values:
      auth:
        username: alertmanager
      persistence:
        enabled: true
        size: 8Gi

  - name: redis
    repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
    values:
      architecture: standalone
      auth:
        enabled: false

  - name: loki-stack
    repository: https://grafana.github.io/helm-charts
    chart: loki-stack
    revision: 2.10.0
    values:
      loki:
        persistence:
          enabled: true
          size: 50Gi
      promtail:
        enabled: true
```

**Generates**: ArgoCD Application with 5 sources -- kube-prometheus-stack + postgresql + rabbitmq + redis + loki-stack.

## Rune from a Git Repository

Instead of pointing at a Helm repository, you can point at a Git repository and specify a `path` to the chart directory. Use `path` instead of `chart`:

```yaml
name: cert-manager
namespace: cert-manager
repository: https://charts.jetstack.io
chart: cert-manager
revision: v1.18.2

values:
  installCRDs: true

runes:
  # Chart from a Git repository (path instead of chart)
  - name: cert-manager-linode
    repository: https://github.com/monostream/cert-manager-linode.git
    path: chart
    revision: main

  # Chart from a Helm repository (chart instead of path)
  - name: external-dns
    repository: https://kubernetes-sigs.github.io/external-dns/
    chart: external-dns
    revision: 1.19.0
    values:
      provider:
        name: linode
      sources:
        - service
        - ingress
        - istio-virtualservice
```

The key difference:

| Source Type | Fields | Example |
|---|---|---|
| Helm repository | `repository` + `chart` + `revision` | `chart: external-dns`, `revision: 1.19.0` |
| Git repository | `repository` + `path` + `revision` | `path: chart`, `revision: main` |

## Rune Fallback (defaultTrinket)

When a rune has `values` but no `repository`, `chart`, or `path`, it falls back to the book's `defaultTrinket` (typically summon). This lets you deploy multiple workloads in a single ArgoCD Application without needing external charts.

```yaml
name: my-platform
namespace: applications

# Source 1: API server (via summon defaultTrinket)
image:
  repository: myorg/api
  tag: v1.0.0

workload:
  type: deployment
  replicas: 3

service:
  enabled: true
  ports:
    - port: 80
      targetPort: 8080
      name: http

# Source 2 and 3: Additional workloads via rune fallback
runes:
  # Background worker -- no repository/chart, falls back to summon
  - values:
      name: background-worker
      workload:
        type: deployment
        replicas: 5
      image:
        repository: myorg/worker
        tag: v1.0.0
      envs:
        WORKER_MODE: "true"

  # Database -- no repository/chart, falls back to summon
  - values:
      name: app-database
      workload:
        type: statefulset
        replicas: 1
        volumeClaimTemplates:
          data:
            size: 10Gi
            destinationPath: /var/lib/postgresql/data
      image:
        repository: postgres
        tag: "15"
      service:
        enabled: true
        ports:
          - port: 5432
            name: postgres
```

**Generates**: ArgoCD Application with 3 summon sources -- API Deployment + Worker Deployment + PostgreSQL StatefulSet.

You can also mix fallback runes with external chart runes:

```yaml
name: rune-mix-example

image:
  repository: nginx
  tag: latest

service:
  enabled: true

runes:
  # Fallback rune (uses defaultTrinket/summon)
  - values:
      workload:
        type: statefulset
        replicas: 1
      image:
        repository: postgres
        tag: "15"

  # External chart rune
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
    values:
      auth:
        enabled: false
```

## Rune Inheritance

Runes follow the same cascading merge system as all other spell configuration. You can define runes at three levels, and they accumulate:

### Book-Level Runes

Define runes in `index.yaml` to apply them to every spell in the book:

```yaml
# bookrack/production/index.yaml
name: production
chapters:
  - infrastructure
  - applications

defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream

# These runes are inherited by every spell in the book
runes:
  - name: datadog-agent
    repository: https://helm.datadoghq.com
    chart: datadog
    revision: 3.50.0
    values:
      datadog:
        clusterName: production
```

### Chapter-Level Runes

Define runes in a chapter's `index.yaml` to apply them to all spells in that chapter:

```yaml
# bookrack/production/applications/index.yaml
name: applications

# These runes are added to every spell in this chapter
runes:
  - name: fluentbit-sidecar
    repository: https://fluent.github.io/helm-charts
    chart: fluent-bit
    revision: 0.40.0
    values:
      config:
        outputs: |
          [OUTPUT]
              Name  forward
              Host  fluentd.monitoring.svc
```

### Spell-Level Runes

Define runes directly in the spell file (the most common pattern):

```yaml
# bookrack/production/applications/api.yaml
name: api
image: myorg/api:v1.0

runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 18.0.0
```

### How They Merge

Runes from all three levels are concatenated. The final Application gets sources from book runes + chapter runes + spell runes, all appended after the primary source and any trinket sources.

```
Book runes (index.yaml)
  + Chapter runes (chapter/index.yaml)
    + Spell runes (spell.yaml)
      = All rune sources in the ArgoCD Application
```

## Runes + Glyphs Combo

Runes and glyphs serve different purposes and combine naturally. Use glyphs for runik-native infrastructure patterns (vault secrets, istio routing, certificates) and runes for external charts that run alongside your workload.

Here is a real-world example: an external chart (cert-manager) with glyphs for secrets and DNS, plus runes for DNS provider extensions:

```yaml
name: cert-manager
namespace: cert-manager
repository: https://charts.jetstack.io
chart: cert-manager
revision: v1.18.2

appParams:
  disableAutoSync: true

values:
  installCRDs: true

# Glyphs: runik-native infrastructure patterns
glyphs:
  vault:
    prolicy:
      type: prolicy

    linode-api-token:
      type: secret
      name: linode-api-token
      path: book
      keys:
        - LINODE_API_TOKEN

    pihole-admin-password:
      type: secret
      name: pihole-admin-password
      path: chapter
      keys:
        - PIHOLE_PASSWORD

  cert-manager:
    default-issuer:
      type: clusterIssuer
      enabled: true
      nameOverride: default-issuer
      email: admin@example.com
      issuerType: linode
      linode:
        secret:
          name: linode-api-token
          key: LINODE_API_TOKEN

    service-a:
      type: dnsEndpoint
      dnsName: "service-a.int.example.com"
      target: "10.42.0.100"

# Runes: external charts for DNS providers
runes:
  - name: cert-manager-linode
    repository: https://github.com/monostream/cert-manager-linode.git
    path: chart
    revision: main

  - name: external-dns
    repository: https://kubernetes-sigs.github.io/external-dns/
    chart: external-dns
    revision: 1.19.0
    values:
      provider:
        name: linode
      sources:
        - service
        - ingress
        - istio-virtualservice
      env:
        - name: LINODE_TOKEN
          valueFrom:
            secretKeyRef:
              name: linode-api-token
              key: LINODE_API_TOKEN

  - name: internal-dns
    repository: https://kubernetes-sigs.github.io/external-dns/
    chart: external-dns
    revision: 1.19.0
    values:
      nameOverride: internal-dns
      provider:
        name: pihole
      registry: noop
      env:
        - name: EXTERNAL_DNS_PIHOLE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: pihole-admin-password
              key: PIHOLE_PASSWORD
```

**Generates**: ArgoCD Application with 5 sources:
1. cert-manager chart (primary)
2. kaster (vault secrets + cert-manager ClusterIssuer + DNS endpoints)
3. cert-manager-linode (rune from Git)
4. external-dns for public domains (rune from Helm)
5. external-dns for internal domains (rune from Helm)

Another example -- a summon-based workload with both glyphs and runes:

```yaml
name: api-service
namespace: applications
image: myorg/api:v2.0

service:
  enabled: true

# Glyphs for infrastructure integration
vault:
  db-creds:
    path: secret/data/production/db

istio:
  route:
    selector:
      access: external
    hosts:
      - api.example.com

# Runes for supporting services
runes:
  - name: prometheus
    repository: https://prometheus-community.github.io/helm-charts
    chart: prometheus
    revision: 25.27.0
    values:
      server:
        enabled: true
        retention: 7d

  - name: jaeger
    repository: https://jaegertracing.github.io/helm-charts
    chart: jaeger
    revision: 3.0.0
    values:
      provisionDataStore:
        cassandra: false
      storage:
        type: memory
```

**Generates**: ArgoCD Application with 4 sources: summon + kaster (vault + istio) + prometheus + jaeger.

## When to Use Runes vs Glyphs

| Scenario | Use | Why |
|---|---|---|
| Vault secrets, istio routing, certificates | **Glyphs** | These are runik-native patterns with built-in template logic |
| External Helm charts (redis, postgresql, kafka) | **Runes** | Third-party charts deployed as additional ArgoCD sources |
| Shared infrastructure (gateways, issuers, vault) | **Glyphs + Lexicon** | Register in the lexicon so all spells can discover them dynamically |
| App-specific dependencies (sidecar DB, cache) | **Runes** | Co-deployed with the application in the same ArgoCD Application |
| Reusable infrastructure patterns you author | **Create a glyph** | Glyphs are templated, versioned, and distributed via kaster |
| One-off chart you need once | **Runes** | No need to create a glyph for a chart used in a single spell |
| Multi-component app (API + worker + DB) | **Rune fallback** | Use runes without `repository`/`chart` to deploy multiple summon workloads |
| DNS, storage, event buses | **Glyphs** (if a glyph exists) or **Runes** (if not) | Check available glyphs first; fall back to runes for unsupported charts |

**Rule of thumb**: If Runik Platform has a glyph for it, use the glyph. If it is a third-party chart, use a rune. If you find yourself writing the same rune in multiple spells, consider creating a glyph.

## Cross-References

- [spells.md](spells.md) -- Spell types and how runes fit into type 6
- [bookrack.md](bookrack.md) -- Configuration hierarchy and how runes inherit across levels
- [glyphs.md](glyphs.md) -- Available glyph types and when to use them instead of runes
- [lexicon.md](lexicon.md) -- Registering infrastructure for dynamic discovery
- [summon.md](summon.md) -- Workload fields used in rune fallback mode
- [deploying.md](deploying.md) -- How the Librarian processes runes into ArgoCD Applications
