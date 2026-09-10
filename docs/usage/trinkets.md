# Trinkets

## What is a Trinket?

A **trinket** is a specialized Helm chart in Runik Platform that provides domain-specific functionality with opinionated defaults. Where summon is a general-purpose workload chart and glyphs are infrastructure templates, trinkets encode an entire domain -- microservice conventions, event-driven workflows, or identity management -- into a single, purpose-built chart.

Trinkets are registered in a book's `index.yaml` and triggered automatically when specific keys appear in a spell.

### When to Use Each

| Component | Purpose | Triggered By | Example |
|-----------|---------|--------------|---------|
| **Summon** | General workloads (Deployment, Job, CronJob, etc.) | `image:` key in spell | A REST API, a background worker, a cron job |
| **Glyphs** | Infrastructure templates (Vault, Istio, cert-manager) | Glyph keys (`vault:`, `istio:`, `cert-manager:`) | A TLS certificate, a VirtualService, a VaultSecret |
| **Trinkets** | Domain-specific charts with opinionated conventions | Trinket-specific keys or chapter `defaultTrinket` | A microservice with all best practices, an Argo Workflow, a Keycloak realm |

### Registering Trinkets

Trinkets are declared in your book's `index.yaml`:

```yaml
# bookrack/production/index.yaml
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
```

You can override `defaultTrinket` at the chapter level to use microspell for all spells in a chapter:

```yaml
# bookrack/production/applications/index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/microspell.git
  path: .
  revision: upstream
```

---

## Microspell

### What It Is

Microspell is an opinionated microservice chart that bundles summon as a subchart, reuses summon's templates for the CRD-free core resources, and layers service-mesh, Vault, and PostgreSQL primitives on top. Fields that summon already understands flow through unchanged; microspell adds a two-replica workload default and service-level integrations.

### When to Use Microspell

Use microspell when you are building cloud-native microservices and want best-practice defaults out of the box. If you find yourself repeating the same summon configuration across many services (replicas, probes, metrics, security), microspell eliminates that boilerplate.

### Summon vs Microspell

Here is the same microservice defined with summon (38 lines) and microspell (5 lines):

**With summon** -- you specify everything:

```yaml
name: user-api
image: myorg/user-api:v2.1.0

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
      name: http

probes:
  liveness:
    type: httpGet
    path: /healthz
    port: 8080
    initialDelaySeconds: 30
    periodSeconds: 10
  readiness:
    type: httpGet
    path: /ready
    port: 8080
    initialDelaySeconds: 5
    periodSeconds: 5

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"

securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
```

**With microspell** -- conventions handle the rest:

```yaml
name: user-api
image: myorg/user-api:v2.1.0

service:
  enabled: true
```

Microspell defaults to two replicas (summon defaults to one) and adds service-level Istio mesh features once `service.enabled` is true. Autoscaling is disabled by default; when enabled its defaults are 2-10 replicas at 70% CPU. Probe, Prometheus annotation, and SecurityContext fields are not auto-populated -- add them to the spell the same way you would with summon.

### Microspell Configuration

To customize microspell behavior, you override only what differs from the defaults:

```yaml
name: payment-service
image: myorg/payment:v3.0.0

# Simple environment variables
envs:
  ENV: production
  LOG_LEVEL: info
  API_TIMEOUT: "30s"

# Override defaults
workload:
  replicas: 5

autoscaling:
  enabled: true
  minReplicas: 5
  maxReplicas: 20

# Service configuration
service:
  enabled: true
  external: true
  timeout: 60s
  circuitBreaking:
    enabled: true
    consecutive5xxErrors: 3
  retry:
    enabled: true
    attempts: 3
```

### What Microspell Auto-Configures

When you deploy a microspell, you get the following resources without specifying them:

| Resource | Default Behavior |
|----------|-----------------|
| **Deployment** | 2 replicas, rolling update strategy |
| **Service** | ClusterIP on configured ports |
| **ServiceAccount** | Created with automount enabled |
| **HPA** | Disabled by default; when enabled, defaults to 2-10 replicas at 70% CPU |
| **Istio VirtualService** | Auto-generated when `service.enabled` is true (internal); a second external VirtualService when `service.external` is true |
| **Vault Policy** | Auto-generated when `infrastructure.prolicy.enabled` is true |

Probe, Prometheus annotation, SecurityContext, and related fields are not pre-populated by microspell -- they are passed through to summon unchanged. Set them in the spell when you need them, the same way as with summon.

### Microspell with DataStore

Microspell includes managed PostgreSQL integration via CloudNativePG. Selecting an existing cluster is reserved by the values contract but the external path is currently a stub and produces no PostgreSQL plumbing.

```yaml
name: user-api
image: myorg/user-api:v2.1.0

service:
  enabled: true

dataStore:
  psql:
    enabled: true

    database: users
    username: user_api
```

### Microspell Fields Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `envs` | map | `{}` | Environment variables (key-value pairs) |
| `workload.replicas` | int | `2` | Number of replicas |
| `autoscaling.enabled` | bool | `false` | Create an HPA |
| `autoscaling.minReplicas` | int | `2` | Minimum replicas for HPA |
| `autoscaling.maxReplicas` | int | `10` | Maximum replicas for HPA |
| `autoscaling.targetCPUUtilizationPercentage` | int | `70` | CPU target for autoscaling |
| `service.enabled` | bool | `true` | Create a Service resource |
| `service.external` | bool | `false` | Expose via external Istio gateway |
| `service.circuitBreaking.enabled` | bool | `false` | Enable circuit breaker |
| `service.retry.enabled` | bool | `false` | Enable retry policy |
| `service.timeout` | string | `"30s"` | Request timeout |
| `infrastructure.prolicy.enabled` | bool | `false` | Create Vault policy for the service |
| `dataStore.psql.enabled` | bool | `false` | Enable PostgreSQL integration |
| `secrets` | map | `{}` | Vault secrets (mount as file or env) |

All standard summon fields (`resources`, `probes`, `volumes`, `configMaps`, `initContainers`, `sideCars`, `nodeSelector`, `tolerations`, `affinity`, etc.) are also available and are passed through to summon unchanged.

`glyphs:` is not a microspell-specific field. It is a spell-level key routed by librarian to kaster as a separate ArgoCD source; any spell (summon, microspell, or external-chart based) can use it in the same way. See the root CLAUDE.md `§4` for details.

---

## Tarot

Tarot renders self-contained Argo `WorkflowTemplate` resources. A **card** is
one executable definition; a **reading** composes card executions into a
process. Dependencies are explicit.

Cards are reusable within the normal Runik scopes:

```text
spellbook.tarot.cards < chapter.tarot.cards < spell.tarot.cards
```

They do not use `appendix`, the lexicon, a deck, or a global registry.

### Local reading

```yaml
name: api-ci-pipeline
namespace: ci

tarot:
  executionMode: dag
  cards:
    checkout:
      container:
        image: alpine/git:latest
        command: ["git", "clone", "https://example.com/api.git", "/workspace"]
    test:
      container:
        image: golang:1.24
        command: ["go", "test", "./..."]
  reading:
    cards:
      clone:
        uses: checkout
      verify:
        uses: test
        depends: [clone]
```

### Tarot Configuration Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tarot.executionMode` | string | `dag` | `dag` or `containerSet` |
| `tarot.cards` | map | `{}` | Reusable card definitions in the current scope |
| `tarot.reading.cards` | map | — | Executions keyed by task name |
| `tarot.reading.onExit` | card execution | — | One reusable or inline card that runs after success, failure, or error |
| `tarot.reading.selector` | map | — | Exact selector for one published `tarot-reading` |
| `tarot.defaultReading` | map | — | Inherited reading used when the spell omits `reading` |
| `tarot.extend` | map | `{}` | Card subgraphs inserted at declared extension points |
| `tarot.with` | map | `{}` | Values for reading input parameters |
| `tarot.serviceAccount.name` | string | `tarot-runner` | Workflow runner ServiceAccount |
| `tarot.secrets` | map | `{}` | Workflow-owned Kubernetes or Vault secrets |
| `tarot.volumes` | map | `{}` | Workflow volumes and PVC declarations |
| `tarot.configMaps` | map | `{}` | Workflow-owned ConfigMaps |
| `tarot.rbac.triggerServiceAccounts` | list | `[]` | External Sensor ServiceAccounts allowed to submit |
| `tarot.ttlStrategy` | map | success `1d`, failure `7d` | Lifetime of completed Workflow objects |
| `tarot.podGC` | map | completion + `30m` delay | Garbage collection of completed Workflow pods |

### Card Definition Fields

Each reusable card has exactly one implementation: `container`, `script`,
`resource`, `suspend`, or `ref`. A reading entry either sets `uses` or
defines one of those implementations inline.

| Field | Location | Description |
|-------|----------|-------------|
| `contract.inputs` / `contract.outputs` | reusable card | Accepted/produced parameters, artifacts, and required secrets |
| `uses` | reading card | Reusable card name |
| `depends` | reading card | Explicit upstream task names |
| `with` | reading card | Parameter bindings validated against the card contract |
| `artifacts` | reading card | Explicit artifact bindings; otherwise Tarot resolves one producer from dependencies |
| `when`, `hooks`, `continueOn` | DAG reading card | Native Argo task controls |

`containerSet` cards must resolve to native containers and exchange data
through shared volumes. Template references, artifacts, `when`, and per-card
retry/timeout are DAG-only.

### Retention and process cleanup

Tarot gives every generated Workflow a bounded lifetime by default:

```yaml
tarot:
  ttlStrategy:
    secondsAfterSuccess: 86400
    secondsAfterFailure: 604800
  podGC:
    strategy: OnWorkflowCompletion
    deleteDelayDuration: 30m
```

The policies follow normal Tarot inheritance and apply to both composed and
selected readings. Override either map at spellbook, chapter, or spell scope;
set it to `null` to disable the inherited policy.

Retention only removes Kubernetes execution objects. Process cleanup belongs
to the reading and must not be chained only to its successful DAG path:

```yaml
tarot:
  reading:
    onExit:
      uses: finalize
      with:
        status: "{{workflow.status}}"
    cards:
      execute:
        uses: operation
```

The exit execution accepts the same `uses` or inline implementation shape as
a card execution. It may bind parameters and secrets, but cannot depend on DAG
cards or consume their artifacts.

### Defaults, extensions, and named readings

There can be one effective `defaultReading` after book, chapter, and spell
precedence. A reading can declare `extensionPoints`; callers add a subgraph
through `tarot.extend`. Other organizational processes should be published as
named readings rather than additional defaults.

Publish only the reference and input contract:

```yaml
appendix:
  lexicon:
    organization-ci:
      type: tarot-reading
      labels: {process: ci, profile: standard, version: v1}
      scope: namespace
      namespace: organization-ci
      template: main
      contract:
        inputs:
          parameters:
            repository: {required: true}
```

Consumers select it through `tarot.reading.selector`. The complete reading and
its cards stay under `tarot`; only the small reference belongs in the lexicon.
A namespaced reading can only be selected from the same namespace. Cluster
scope refers to an independently provided `ClusterWorkflowTemplate`; Tarot's
composed readings are namespaced.

### Events

Tarot does not create Sensors or EventSources. A process publishes a
`workflow-trigger` lexicon entry with:

- `sensorSelector`: selects the infrastructure-owned Sensor;
- `readingSelector`: selects one published `tarot-reading`;
- `filters` or `match`: isolates its event condition;
- `parameters`: maps event data into the reading contract.

The `argo-events` Sensor performs the inverse lookup while rendering and adds
all publications that select it. This keeps one Sensor owner and avoids
duplicating event infrastructure.

---

## Covenant

**Related system, not a trinket.** Covenant is a path-based IAM application
renderer, not a trinket and not a
Librarian book. One instance compiles one IAM book into one organization and
realm. That IAM input owns identities and RBAC; ordinary deployable books
publish the application role and client contracts Covenant selects.

### Invocation

Invoke it through a path-based spell with `appParams.bookData: true`:

```yaml
name: covenant-example
namespace: covenant-example
repository: https://github.com/runik-platform/runik.git
path: covenant
revision: upstream
appParams:
  bookData: true
values:
  applicationSet:
    source:
      repository: https://github.com/runik-platform/runik.git
      path: covenant
      revision: upstream
```

Librarian emits one Argo CD Application and passes the book context and
consolidated Lexicon. Covenant reads the separate IAM input through
`covenant/bookrack -> ../bookrack` and renders the complete realm in that
Application. The `applicationSet.source` block tells principal shards how to
invoke the same chart; it is deployment wiring, not IAM data.
The canonical layout, defaults, and examples are in
[`covenant/docs/contracts.md`](../../covenant/docs/contracts.md). Run
`make test covenant` to validate the complete fixture without contacting a
cluster.

---

## Cross-References

- [spells.md](spells.md) -- Spell types, including how trinkets are triggered (Type 7: tarot)
- [bookrack.md](bookrack.md) -- Book `index.yaml` trinket registration and chapter `defaultTrinket` overrides
- [summon.md](summon.md) -- All workload fields available in microspell (microspell inherits summon)
- [glyphs.md](glyphs.md) -- Glyph types used by trinkets (vault, istio, cert-manager, keycloak)
- [lexicon.md](lexicon.md) -- How the runic indexer resolves Tarot reading/event references and Covenant lookups
- [runes.md](runes.md) -- Adding external charts alongside trinkets
