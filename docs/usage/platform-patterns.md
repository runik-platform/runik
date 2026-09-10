# Platform Patterns

This document covers platform-scale patterns for Runik Platform: multi-environment promotion, multi-tenant isolation, multi-cluster routing, standardization strategies, self-service infrastructure, migration paths, and security best practices. Each section is self-contained with working examples you can adapt to your organization.

## Multi-Environment

You model environments by creating separate books in the bookrack. Each book has its own `index.yaml` with environment-specific lexicon entries, while spells remain identical across environments.

### Example: Three-Environment Layout

```
bookrack/
├── dev/
│   ├── index.yaml
│   ├── infrastructure/
│   │   └── gateway.yaml
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
├── staging/
│   ├── index.yaml
│   ├── infrastructure/
│   │   └── gateway.yaml
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
└── prod/
    ├── index.yaml
    ├── infrastructure/
    │   └── gateway.yaml
    └── applications/
        ├── api-service.yaml
        └── frontend.yaml
```

### Same Spells, Different Lexicon

The spell files across `dev/`, `staging/`, and `prod/` are identical. Environment-specific behavior comes from the lexicon registered in each book's `index.yaml`.

**dev/index.yaml**:

```yaml
name: dev

chapters:
  - infrastructure
  - applications

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

appendix:
  lexicon:
    vault:
      type: vault
      url: https://vault.dev.svc:8200
      namespace: vault
      labels:
        environment: dev
        default: book
    external-gateway:
      type: istio-gw
      gateway: istio-system/external-gateway
      baseURL: dev.example.com
      labels:
        access: external
        default: book
```

**prod/index.yaml**:

```yaml
name: prod

chapters:
  - infrastructure
  - applications

defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: <published-summon-tag-or-commit>

trinkets:
  kaster:
    key: glyphs
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: <published-kaster-tag-or-commit>

appendix:
  lexicon:
    vault:
      type: vault
      url: https://vault.prod.svc:8200
      namespace: vault
      labels:
        environment: production
        default: book
    external-gateway:
      type: istio-gw
      gateway: istio-system/external-gateway
      baseURL: example.com
      labels:
        access: external
        default: book
```

**Shared spell (identical in all three books) -- applications/api-service.yaml**:

```yaml
name: api-service
namespace: applications
image: myorg/api:v2.1.0

service:
  enabled: true
  ports:
    - port: 8080
      name: http

glyphs:
  vault:
    db-creds:
      type: secret
      format: env
      keys:
        - DATABASE_URL
        - API_KEY

  istio:
    api-route:
      type: virtualService
      selector:
        access: external
      subdomain: api
      httpRules:
        - prefix: /
          port: 8080
```

The spell references `selector: { access: external }` without naming a specific gateway. The runic indexer resolves this against each book's lexicon, so the same spell routes through `dev.example.com` in dev and `example.com` in prod.

### Progressive Rollout: dev to staging to prod

Use this workflow to promote changes safely:

```bash
# 1. Deploy to dev -- uses master branch charts
helm template librarian/ --set name=dev | kubectl apply -f -

# 2. Validate in dev, then copy spells to staging
cp bookrack/dev/applications/api-service.yaml \
   bookrack/staging/applications/api-service.yaml

# 3. Deploy to staging
helm template librarian/ --set name=staging | kubectl apply -f -

# 4. After staging validation, promote to prod
cp bookrack/staging/applications/api-service.yaml \
   bookrack/prod/applications/api-service.yaml

# 5. Deploy to prod -- note: prod pins chart revisions
helm template librarian/ --set name=prod | kubectl apply -f -
```

Pin chart revisions in production by setting a release tag in the prod
`index.yaml` while dev and staging use `revision: upstream`. This gives you
stability in production and fast iteration in lower environments.

| Environment | Chart Revision | Vault URL | Base URL | Auto-sync |
|-------------|---------------|-----------|----------|-----------|
| dev | `upstream` | `vault.dev.svc` | `dev.example.com` | Enabled |
| staging | `upstream` | `vault.staging.svc` | `staging.example.com` | Enabled |
| prod | `v1.4.0` (pinned) | `vault.prod.svc` | `example.com` | Enabled (with prune) |

---

## Multi-Tenant

You isolate tenants by giving each one its own book. Each book carries a `namePrefix` so that all resources generated for that tenant are namespaced and non-colliding.

### Example: Per-Tenant Books

```
bookrack/
├── tenant-acme/
│   ├── index.yaml
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
├── tenant-globex/
│   ├── index.yaml
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
└── tenant-initech/
    ├── index.yaml
    └── applications/
        ├── api-service.yaml
        └── frontend.yaml
```

### namePrefix for Isolation

Set `namePrefix` at the book level so every ArgoCD Application and Kubernetes resource carries the tenant identity.

**tenant-acme/index.yaml**:

```yaml
name: tenant-acme
namePrefix: acme-

chapters:
  - applications

projectName: tenant-acme

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

appendix:
  lexicon:
    vault:
      type: vault
      url: https://vault.platform.svc:8200
      namespace: vault
      labels:
        tenant: acme
        default: book
    external-gateway:
      type: istio-gw
      gateway: istio-system/external-gateway
      baseURL: acme.example.com
      labels:
        access: external
        default: book
```

With `namePrefix: acme-`, the spell `api-service` produces an ArgoCD Application named `acme-api-service` deploying into namespace `acme-api-service` (or whatever namespace the spell specifies).

### Dedicated Infrastructure per Tenant

When a tenant needs its own infrastructure (database cluster, vault namespace, Istio gateway), give that tenant a dedicated `infrastructure` chapter.

```yaml
# tenant-acme/index.yaml
name: tenant-acme
namePrefix: acme-

chapters:
  - infrastructure    # Tenant-specific infra
  - applications

appendix:
  lexicon:
    vault:
      type: vault
      url: https://vault.platform.svc:8200
      namespace: tenant-acme
      labels:
        tenant: acme
        default: book
```

```yaml
# tenant-acme/infrastructure/gateway.yaml
name: acme-gateway
namespace: istio-system

glyphs:
  istio:
    acme-gw:
      type: istio-gw
      hosts:
        - "*.acme.example.com"
      istioSelector:
        istio: acme-gateway
      tls:
        enabled: true

  cert-manager:
    acme-cert:
      type: certificate
      dnsNames:
        - "*.acme.example.com"

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      gateway: istio-system/acme-gateway
      baseURL: acme.example.com
      labels:
        access: external
        default: book
```

### Shared Infrastructure Book

If multiple tenants share infrastructure, create a separate book that deploys shared components and registers them in the lexicon. Tenant books then reference those entries.

```
bookrack/
├── shared-infra/
│   ├── index.yaml
│   ├── infrastructure/
│   │   ├── istio-gateway.yaml
│   │   ├── cert-manager.yaml
│   │   └── vault.yaml
│   └── databases/
│       └── shared-postgres.yaml
├── tenant-acme/
│   ├── index.yaml
│   └── applications/
│       └── ...
└── tenant-globex/
    ├── index.yaml
    └── applications/
        └── ...
```

Deploy the shared infrastructure book first:

```bash
helm template librarian/ --set name=shared-infra | kubectl apply -f -
```

Then deploy each tenant:

```bash
helm template librarian/ --set name=tenant-acme | kubectl apply -f -
helm template librarian/ --set name=tenant-globex | kubectl apply -f -
```

| Isolation Level | namePrefix | Separate Gateway | Separate Vault NS | Separate Cluster |
|----------------|------------|-----------------|-------------------|-----------------|
| Namespace-only | Yes | No | No | No |
| Network-isolated | Yes | No | Yes | No |
| Fully dedicated | Yes | Yes | Yes | Yes |

---

## Multi-Cluster and Regional Deployments

You target specific clusters by registering them as lexicon entries with `type: k8s-cluster` and using `clusterSelector` in your spells or book `index.yaml`. The librarian resolves the cluster URL through the runic indexer and sets `destination.server` on the generated ArgoCD Application.

### Register Clusters in the Lexicon

Add cluster entries to your book's `appendix.lexicon` in the `index.yaml`, in a chapter `index.yaml`, or in a spell's `appendix`:

```yaml
# us-west/index.yaml
name: us-west

chapters:
  - infrastructure
  - applications

appendix:
  lexicon:
    primary-cluster:
      type: k8s-cluster
      labels:
        region: us-west
        environment: production
        default: book
      clusterURL: https://k8s-us-west.example.com
```

### clusterSelector in Spells

Set `clusterSelector` at the book, chapter, or spell level. The librarian queries the lexicon for entries of `type: k8s-cluster` matching all selector labels (AND logic) and uses the resulting `clusterURL` as the ArgoCD Application's `destination.server`.

**Book-level (all spells deploy to this cluster)**:

```yaml
# regional-us-west/index.yaml
name: regional-us-west

clusterSelector:
  region: us-west
  environment: production

chapters:
  - applications
```

**Spell-level (override for a specific spell)**:

```yaml
# applications/latency-sensitive-api.yaml
name: latency-sensitive-api
image: myorg/api:v1.0

clusterSelector:
  region: eu-central
  environment: production

service:
  enabled: true
```

### Regional Deployment Layout

```
bookrack/
├── us-west/
│   ├── index.yaml          # clusterSelector: { region: us-west }
│   ├── infrastructure/
│   │   └── gateway.yaml
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
├── us-east/
│   ├── index.yaml          # clusterSelector: { region: us-east }
│   └── applications/
│       ├── api-service.yaml
│       └── frontend.yaml
└── eu-central/
    ├── index.yaml          # clusterSelector: { region: eu-central }
    └── applications/
        ├── api-service.yaml
        └── frontend.yaml
```

Deploy all regions from a single ArgoCD instance:

```bash
helm template librarian/ --set name=us-west | kubectl apply -f -
helm template librarian/ --set name=us-east | kubectl apply -f -
helm template librarian/ --set name=eu-central | kubectl apply -f -
```

### How Cluster Resolution Works

The librarian template performs this resolution:

1. Reads `clusterSelector` from the spell, falling back to chapter, then book.
2. Calls the runic indexer with the selector and `type: k8s-cluster`.
3. The indexer returns all matching lexicon entries (AND on all labels).
4. The last matching entry's `clusterURL` becomes `destination.server`.
5. If no `clusterSelector` is set or no match is found, the destination defaults to `https://kubernetes.default.svc` (the local cluster).

| Selector Level | Scope | Override Behavior |
|---------------|-------|-------------------|
| Book `index.yaml` | All spells in the book | Baseline for the book |
| Chapter `index.yaml` | All spells in the chapter | Overrides book-level |
| Spell YAML | Single spell | Overrides chapter and book |

---

## Standardization Strategies

### Golden Paths with Glyphs

Glyphs let you encode infrastructure patterns -- monitoring, networking, TLS, secret management -- as reusable building blocks. Developers integrate them with a few lines in their spell rather than writing raw Kubernetes manifests.

**Platform team encodes the monitoring pattern once (as a glyph)**:

```yaml
# A developer gets Prometheus scraping, Grafana dashboard, and alerting rules
# by adding this to their spell:
glyphs:
  free-form:
    service-monitor:
      type: manifest
      definition:
        apiVersion: monitoring.coreos.com/v1
        kind: ServiceMonitor
        metadata:
          name: api-service-monitor
          labels:
            release: kube-prometheus-stack
        spec:
          selector:
            matchLabels:
              app: api-service
          endpoints:
            - port: metrics
              interval: 15s
              path: /metrics
```

**Developer uses it -- one-line integration**:

```yaml
# applications/api-service.yaml
name: api-service
image: myorg/api:v1.0

service:
  enabled: true
  ports:
    - port: 8080
      name: http
    - port: 9090
      name: metrics

glyphs:
  istio:
    api-route:
      type: virtualService
      selector:
        access: external
      subdomain: api
      httpRules:
        - prefix: /
          port: 8080

  vault:
    db-creds:
      type: secret
      format: env
      keys:
        - DATABASE_URL

  cert-manager:
    api-cert:
      type: certificate
      dnsNames:
        - api.example.com
```

From the developer's perspective, they declare intent (`vault`, `istio`, `cert-manager`). The glyphs produce the actual VaultSecret, VirtualService, and Certificate resources.

### Defaults in defaultTrinket

Set platform-wide defaults by adding `values` to the `defaultTrinket` in your book `index.yaml`. Every spell in the book inherits these values unless overridden.

```yaml
# production/index.yaml
name: production

defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream
  values:
    # Platform-wide security defaults
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      capabilities:
        drop:
          - ALL
      readOnlyRootFilesystem: true

    # Platform-wide resource defaults
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi

    # Platform-wide probe defaults
    probes:
      liveness:
        httpGet:
          path: /healthz
          port: 8080
        initialDelaySeconds: 15
        periodSeconds: 10
      readiness:
        httpGet:
          path: /ready
          port: 8080
        initialDelaySeconds: 5
        periodSeconds: 5

    # Platform-wide service account
    serviceAccount:
      enabled: true
      automount: true

chapters:
  - infrastructure
  - applications
```

Now a minimal spell automatically gets security contexts, resource limits, health probes, and a service account:

```yaml
# With defaults above, this 3-line spell gets full production configuration
name: api-service
image: myorg/api:v2.0
service:
  enabled: true
```

A spell can override any default:

```yaml
name: heavy-worker
image: myorg/worker:v1.0
resources:
  requests:
    cpu: 2000m        # Override the 100m default
    memory: 4Gi
  limits:
    cpu: 4000m
    memory: 8Gi
```

### Microspell: Maximum Convention Over Configuration

Microspell is an opinionated trinket built on top of summon. It adds Vault integration, Istio routing, PostgreSQL provisioning, and observability metadata to a single concise spell. Register it as the `defaultTrinket` for a chapter to make all spells in that chapter use microspell conventions.

**Set microspell as defaultTrinket for an applications chapter**:

```yaml
# production/applications/index.yaml
name: applications

defaultTrinket:
  repository: https://github.com/runik-platform/microspell.git
  path: .
  revision: upstream
```

**A microspell-powered spell**:

```yaml
name: user-service
image:
  repository: registry.example.com/user-service
  tag: v1.2.0

service:
  enabled: true
  external: true
  ports:
    - port: 80
      name: http
  prefix: /api/users

metadata:
  owners:
    - platform-team
  org: example.com
  serviceLevel: 5
  type: backend
  lang: go

envs:
  ENV: production
  LOG_LEVEL: info

dataStore:
  psql:
    enabled: true
    database: user_service
    cluster:
      instances: 2
      storage:
        size: 20Gi

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
```

This single spell produces a Deployment, Service, VirtualService (external), PostgreSQL cluster (via CNPG), Vault credentials, service account, and observability labels -- all from microspell conventions.

| Strategy | Scope | Complexity | Best For |
|----------|-------|-----------|----------|
| Glyphs | Per-spell integration | Low | Adding specific infrastructure to any spell |
| defaultTrinket values | Book or chapter wide | Low | Enforcing platform defaults |
| Microspell | Full microservice lifecycle | Medium | Teams deploying many similar microservices |

---

## Self-Service Infrastructure

In the self-service model, the platform team controls patterns, defaults, and policies. Developers provision infrastructure by adding glyph entries to their spells. No tickets, no waiting.

### What the Developer Writes

```yaml
# applications/payment-api.yaml
name: payment-api
image: myorg/payment-api:v3.1.0

service:
  enabled: true
  ports:
    - port: 8080
      name: http

glyphs:
  # Developer requests a database
  postgresql:
    payment-db:
      type: database
      dbName: payments
      userName: payment_api
      secret: payment-db-credentials

  # Developer requests secrets from Vault
  vault:
    payment-db-credentials:
      type: secret
      secretType: kubernetes.io/basic-auth
      staticData:
        username: payment_api
      randomKeys:
        - password

    payment-api-keys:
      type: secret
      format: env
      randomKeys:
        - JWT_SECRET
        - ENCRYPTION_KEY

  # Developer requests external routing
  istio:
    payment-route:
      type: virtualService
      selector:
        access: external
      subdomain: payments
      httpRules:
        - prefix: /api/payments
          port: 8080

  # Developer requests a TLS certificate
  cert-manager:
    payment-cert:
      type: certificate
      dnsNames:
        - payments.example.com
```

### What the Platform Team Controls

The platform team controls behavior through:

1. **Glyph implementations** -- The glyph templates define what Kubernetes resources are actually created. A `vault` glyph of `type: secret` always creates a properly configured VaultStaticSecret with the organization's Vault path conventions.

2. **Lexicon entries** -- The book's lexicon determines which Vault instance, which Istio gateway, and which certificate issuer the spell's selectors resolve to.

3. **defaultTrinket values** -- Security contexts, resource limits, and probe requirements are set once and inherited by all spells.

4. **ArgoCD projects** -- Each book gets its own ArgoCD AppProject (`projectName` in `index.yaml`), limiting what clusters and namespaces the tenant can deploy to.

The developer never writes raw Kubernetes manifests. They declare intent, and the platform's glyphs, lexicon, and defaults shape the output.

---

## Migration from kubectl

If you currently deploy with `kubectl apply` commands or shell scripts, follow this four-step migration.

### Step 1: Inventory Your Resources

```bash
# List all deployments across namespaces
kubectl get deployments --all-namespaces -o wide

# Export a specific deployment
kubectl get deployment api-service -n applications -o yaml > api-service-export.yaml
```

### Step 2: Convert to Spells

Take a kubectl-managed Deployment and convert it to a spell.

**Before (raw Kubernetes YAML, 40+ lines)**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: applications
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
    spec:
      containers:
        - name: api-service
          image: myorg/api:v2.0
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: db-creds
                  key: url
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
```

**After (spell YAML, 15 lines)**:

```yaml
name: api-service
namespace: applications
image: myorg/api:v2.0

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
      name: http

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

envs:
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: db-creds
        key: url

probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
```

### Step 3: Parallel Run

Deploy the runik-managed version alongside the existing one to verify they produce identical resources.

```bash
# Generate the ArgoCD Application without applying
helm template librarian/ --set name=migration-test > generated.yaml

# Compare with existing resources
kubectl diff -f generated.yaml
```

### Step 4: Cutover

Once the diff is clean, apply the runik-managed version and remove the old resources.

```bash
# Apply the runik-managed book
helm template librarian/ --set name=production | kubectl apply -f -

# Verify ArgoCD shows the application as synced
kubectl get applications -n argocd

# Remove old kubectl-managed resources (ArgoCD now owns them)
```

---

## Migration from Helm Charts

If you maintain your own Helm charts with `Chart.yaml` and `templates/`, you can eliminate template maintenance by converting to Runik Platform spells.

### Before: Custom Helm Chart

```
my-api-chart/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── deployment.yaml       # 50 lines of Go templates
│   ├── service.yaml          # 20 lines of Go templates
│   ├── ingress.yaml          # 30 lines of Go templates
│   ├── serviceaccount.yaml   # 15 lines of Go templates
│   ├── hpa.yaml              # 20 lines of Go templates
│   └── _helpers.tpl          # 40 lines of Go templates
```

You maintain 175+ lines of Go template code for every chart.

### After: Runik Spell

```yaml
# bookrack/production/applications/api-service.yaml
name: api-service
namespace: applications
image: myorg/api:v2.0

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
      name: http

serviceAccount:
  enabled: true

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

glyphs:
  istio:
    api-route:
      type: virtualService
      selector:
        access: external
      subdomain: api
      httpRules:
        - prefix: /
          port: 8080

  vault:
    api-secrets:
      type: secret
      format: env
      keys:
        - DATABASE_URL
        - API_KEY
```

Summon generates the Deployment, Service, ServiceAccount, and HPA. Kaster generates the VirtualService and VaultStaticSecret. You maintain zero Go templates.

### Keeping External Charts

If you still need a third-party Helm chart (Bitnami, Prometheus, etc.), use it directly in a spell without wrapping it:

```yaml
name: redis
namespace: caching
repository: https://charts.bitnami.com/bitnami
chart: redis
revision: 17.11.3

values:
  auth:
    enabled: true
  master:
    persistence:
      enabled: true
      size: 10Gi

glyphs:
  istio:
    redis-route:
      type: virtualService
      selector:
        access: internal
      hosts:
        - redis.caching.svc
```

The `glyphs:` wrapper keeps infrastructure config separate from the external chart's values.

---

## Security Best Practices

### Least-Privilege ServiceAccounts

Enable dedicated service accounts for every spell. Avoid using the `default` service account in any namespace.

```yaml
name: api-service
image: myorg/api:v1.0

serviceAccount:
  enabled: true
  automount: true
  annotations:
    iam.gke.io/gcp-service-account: api-service@project.iam.gserviceaccount.com
```

Set this as a platform default in your `defaultTrinket.values`:

```yaml
# index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream
  values:
    serviceAccount:
      enabled: true
      automount: true
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      capabilities:
        drop:
          - ALL
      readOnlyRootFilesystem: true
    podSecurityContext:
      fsGroup: 2000
      runAsNonRoot: true
```

### Network Policies via Glyph

Use the `free-form` glyph to deploy NetworkPolicy resources alongside your workloads. This keeps network rules co-located with the services they protect.

```yaml
name: api-service
image: myorg/api:v1.0

service:
  enabled: true

glyphs:
  free-form:
    network-policy:
      type: manifest
      enabled: true
      definition:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        metadata:
          name: api-service-netpol
        spec:
          podSelector:
            matchLabels:
              app: api-service
          policyTypes:
            - Ingress
            - Egress
          ingress:
            - from:
                - namespaceSelector:
                    matchLabels:
                      name: istio-system
              ports:
                - protocol: TCP
                  port: 8080
          egress:
            - to:
                - namespaceSelector:
                    matchLabels:
                      name: databases
              ports:
                - protocol: TCP
                  port: 5432
            - to:
                - namespaceSelector:
                    matchLabels:
                      name: vault
              ports:
                - protocol: TCP
                  port: 8200
```

For a default deny-all policy across a namespace, deploy it as an infrastructure spell:

```yaml
# infrastructure/default-deny.yaml
name: default-deny-policy
namespace: applications

glyphs:
  free-form:
    deny-all:
      type: manifest
      enabled: true
      definition:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        metadata:
          name: default-deny-all
          namespace: applications
        spec:
          podSelector: {}
          policyTypes:
            - Ingress
            - Egress
```

### Secrets via Vault (Never Inline)

Never put secrets directly in spell YAML. Use the `vault` glyph to reference secrets stored in HashiCorp Vault.

```yaml
# WRONG -- secret value in YAML
envs:
  DATABASE_PASSWORD: "s3cret-passw0rd"

# CORRECT -- reference Vault
glyphs:
  vault:
    db-creds:
      type: secret
      format: env
      keys:
        - DATABASE_URL
        - DATABASE_PASSWORD
```

For static secrets that need to be created and stored in Vault:

```yaml
glyphs:
  vault:
    api-credentials:
      type: secret
      format: plain
      staticData:
        username: api_service
      randomKeys:
        - password
        - api_key
```

For TLS secrets managed by Vault:

```yaml
glyphs:
  vault:
    tls-certs:
      type: secret
      secretType: kubernetes.io/tls
      format: plain
      keys:
        - tls.crt
        - tls.key
```

### RBAC via ArgoCD Projects per Book

Each book should have its own ArgoCD AppProject that restricts which repositories, clusters, and namespaces it can access. Set `projectName` in the book `index.yaml`.

```yaml
# tenant-acme/index.yaml
name: tenant-acme
projectName: tenant-acme

chapters:
  - applications
```

The librarian generates an AppProject from the `project.yaml` template. For tighter control, disable the default project generation and create a restricted one manually:

```yaml
# infrastructure/acme-project.yaml
name: acme-argocd-project
namespace: argocd

glyphs:
  free-form:
    argocd-project:
      type: manifest
      enabled: true
      definition:
        apiVersion: argoproj.io/v1alpha1
        kind: AppProject
        metadata:
          name: tenant-acme
          namespace: argocd
        spec:
          sourceRepos:
            - https://github.com/runik-platform/*
            - https://github.com/myorg/tenant-acme-config.git
          destinations:
            - namespace: acme-*
              server: https://kubernetes.default.svc
          clusterResourceWhitelist:
            - group: ""
              kind: Namespace
          namespaceResourceBlacklist:
            - group: ""
              kind: LimitRange
          roles:
            - name: acme-admin
              policies:
                - p, proj:tenant-acme:acme-admin, applications, *, tenant-acme/*, allow
              groups:
                - acme-team
```

### Security Checklist

| Practice | How to Implement | Scope |
|----------|-----------------|-------|
| Dedicated ServiceAccount per workload | `serviceAccount.enabled: true` in defaultTrinket values | Platform-wide |
| Drop all capabilities | `securityContext.capabilities.drop: [ALL]` in defaultTrinket values | Platform-wide |
| Read-only root filesystem | `securityContext.readOnlyRootFilesystem: true` in defaultTrinket values | Platform-wide |
| Run as non-root | `securityContext.runAsNonRoot: true` in defaultTrinket values | Platform-wide |
| Network policies | `free-form` glyph with NetworkPolicy definition | Per-spell or per-namespace |
| Secrets in Vault | `vault` glyph, never inline in spell YAML | Per-spell |
| Scoped ArgoCD projects | `projectName` per book, restricted AppProject spec | Per-tenant or per-book |
| Pinned chart revisions | Published release tag or commit in production `revision` fields | Per-environment |
| Resource limits enforced | `resources.limits` in defaultTrinket values | Platform-wide |

---

## Cross-References

- [bookrack.md](bookrack.md) -- Book and chapter hierarchy, configuration merging, multi-environment layout
- [spells.md](spells.md) -- Spell types, anatomy, detection logic, all seven spell types
- [summon.md](summon.md) -- Complete workload field reference (Deployment, StatefulSet, Job, CronJob, DaemonSet)
- [glyphs.md](glyphs.md) -- Using vault, istio, cert-manager, free-form, and other infrastructure glyphs
- [lexicon.md](lexicon.md) -- Registering infrastructure, runic indexer, label-based discovery
- [runes.md](runes.md) -- Adding external Helm charts as additional ArgoCD sources
- [trinkets.md](trinkets.md) -- Microspell and Tarot reference, plus related Covenant invocation
- [deploying.md](deploying.md) -- Librarian processing, ArgoCD integration, deploy workflow
- [debugging.md](debugging.md) -- Troubleshooting and debug commands
- [../design/architecture.md](../design/architecture.md) -- System overview and data flow
- [../design/librarian.md](../design/librarian.md) -- Two-pass processing, detection logic, cluster resolution
- [../design/merge-system.md](../design/merge-system.md) -- Cascading merge internals
