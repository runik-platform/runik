# Lexicon

## The Problem: Hard-Coded Infrastructure References

Without lexicon, every spell that needs infrastructure must hard-code the details. When you move from staging to production, you rewrite every reference.

**Before -- hard-coded references everywhere:**

```yaml
# bookrack/staging/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

vault:
  db-creds:
    path: secret/data/staging/db

istio:
  route:
    type: virtualService
    gateway: istio-system/staging-gateway   # Hard-coded
    hosts:
      - api.staging.example.com             # Hard-coded
```

```yaml
# bookrack/production/apps/api-service.yaml  (duplicated, changed)
name: api-service
image: myorg/api:v1.0

vault:
  db-creds:
    path: secret/data/production/db

istio:
  route:
    type: virtualService
    gateway: istio-system/prod-gateway      # Changed
    hosts:
      - api.example.com                     # Changed
```

You maintain two copies. Every new service duplicates the same gateway, vault URL, and database host. A gateway rename means editing every spell that references it.

**After -- dynamic discovery via lexicon:**

```yaml
# bookrack/staging/infrastructure/gateway.yaml
name: external-gateway
# ... gateway deployment ...

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: istio-system/staging-gateway
      baseURL: staging.example.com
```

```yaml
# bookrack/staging/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

istio:
  route:
    type: virtualService
    selector:
      access: external        # Discovers the gateway dynamically
    subdomain: api
```

The same `api-service.yaml` spell works in staging and production. Each book registers its own gateway in the lexicon; the spell finds the right one at render time.

## How to Register a Lexicon Entry

You register lexicon entries using `appendix.lexicon` in any spell file, chapter index, or book index. Each entry is a named dictionary with a `type`, `labels`, and data fields specific to that type.

```yaml
# In any spell file
appendix:
  lexicon:
    my-entry-name:                # Unique name for this entry
      type: istio-gw              # Type used for filtering
      labels:                     # Labels used for selector matching
        access: external
        environment: production
        default: book             # Optional: makes this a default
      gateway: istio-system/gw    # Data field (type-specific)
      baseURL: example.com        # Data field (type-specific)
```

### Registration Rules

- The entry name (dictionary key) becomes the `.name` field if one is not explicitly set.
- `type` is required. The Runic Indexer filters entries by type before applying selectors.
- `labels` is required. Selectors match against these labels using AND logic.
- All other fields are data fields passed through to the consuming glyph template.

## How Discovery Works

When a glyph definition includes a `selector`, the Runic Indexer queries the lexicon at render time. Here is the flow:

```
Spell defines glyph with selector
        |
        v
Glyph template calls runicIndexer
        |
        v
Filter lexicon entries by type
        |
        v
Match selector labels against entry labels (AND logic)
        |
        v
Return matching entries to template
```

### Example: Istio VirtualService Discovery

You write this in your spell:

```yaml
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

The istio glyph template calls:

```
runicIndexer(lexicon, {access: external}, "istio-gw", chapterName)
```

The indexer searches all lexicon entries where `type: istio-gw` and `labels.access: external`. It returns the matching gateway entry, and the template uses its `gateway` and `baseURL` fields to generate the VirtualService resource.

### AND Logic for Multiple Selectors

When you provide multiple selector labels, ALL must match. The indexer uses AND logic, not OR.

```yaml
# This selector requires BOTH labels to match
selector:
  access: external
  environment: staging
```

Given this lexicon:

```yaml
lexicon:
  staging-external:
    type: istio-gw
    labels:
      access: external
      environment: staging       # MATCH: both labels match
    gateway: istio-system/staging-gw
    baseURL: staging.example.com

  prod-external:
    type: istio-gw
    labels:
      access: external
      environment: production    # NO MATCH: environment differs
    gateway: istio-system/prod-gw
    baseURL: example.com

  staging-internal:
    type: istio-gw
    labels:
      access: internal           # NO MATCH: access differs
      environment: staging
    gateway: istio-system/internal-gw
    baseURL: int.staging.example.com
```

Only `staging-external` matches because it is the only entry where both `access: external` AND `environment: staging` are true.

## Common Lexicon Types

| Type | Purpose | Data Fields |
|------|---------|-------------|
| `istio-gw` | Istio Gateway reference | `gateway`, `baseURL` |
| `vault` | HashiCorp Vault server | `url`, `namespace`, `serviceAccount`, `authPath`, `secretPath` |
| `database` | Database connection | `host`, `port`, `engine`, `connectionString` |
| `cert-issuer` | Certificate issuer | `issuerName`, `issuerType`, `email` |
| `k8s-cluster` | Kubernetes cluster target | `clusterURL` |
| `event-bus` | Argo Events bus | `name`, `namespace` |
| `event-source` | Argo Events source reference | `name`, `namespace`, `eventName` |
| `tarot-reading` | Published process reference | `scope`, `namespace`, `template`, `contract` |
| `workflow-trigger` | Event subscription for a reading | `sensorSelector`, `readingSelector`, `filters`, `parameters` |
| `s3-provider` | S3-compatible storage | `endpoint`, `region` |

`event-bus` and `event-source` are the canonical spellings. The `argo-events`
glyph continues to accept the historical `eventbus`, `eventBus`, `eventsource`,
and `eventSource` spellings when reading existing books; the generic Runic
Indexer continues to compare types exactly.

> **Deprecated:** the four historical spellings are compatibility aliases only.
> Do not use them in new books. See [Deprecations and Compatibility
> Window](deprecations.md) for their removal policy.

### istio-gw

```yaml
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

Used by the istio glyph to resolve `selector` in VirtualService definitions. The `gateway` field references the Istio Gateway resource as `namespace/name`. The `baseURL` is used to construct the host for routing rules.

### vault

```yaml
appendix:
  lexicon:
    production-vault:
      type: vault
      labels:
        environment: production
        default: book
      url: https://vault.vault.svc:8200
      namespace: vault
      serviceAccount: vault
      authPath: k8s-path-auth
      secretPath: kv
      skipVerify: true
```

Used by the vault glyph to connect to the correct Vault server. Vault secrets, policies, and database engines all resolve their Vault server through the lexicon.

### database

```yaml
appendix:
  lexicon:
    postgres-primary:
      type: database
      labels:
        engine: postgres
        tier: primary
        default: book
      host: postgres-rw.databases.svc
      port: 5432
      connectionString: postgres.data.svc.cluster.local:5432
```

### cert-issuer

```yaml
appendix:
  lexicon:
    default-issuer:
      type: cert-issuer
      labels:
        default: book
      issuerName: default-issuer
      issuerType: linode
      email: admin@example.com
```

### k8s-cluster

```yaml
appendix:
  lexicon:
    dev-cluster:
      type: k8s-cluster
      labels:
        environment: development
        region: us-west-2
        default: book
      clusterURL: https://kubernetes.default.svc
```

Used by the librarian when a spell or book defines `clusterSelector`. The librarian calls the Runic Indexer with type `k8s-cluster` to resolve which cluster to deploy to.

```yaml
# In a spell or book index
clusterSelector:
  environment: development
```

### event-bus

```yaml
appendix:
  lexicon:
    production-eventbus:
      type: event-bus
      labels:
        purpose: ci
        default: book
      name: production-eventbus
      namespace: argo-events
```

Used by the argo-events glyph. EventSources and Sensors find their EventBus through the lexicon via selectors.

### tarot-reading and workflow-trigger

A `tarot-reading` publishes only the address and public input contract of an
existing reading:

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

Its lexicon key supplies the resource name. Do not nest a `reference` object
or publish cards/readings in the appendix. A namespaced reading is selectable
only from that namespace. `scope: cluster` addresses an independently
provided `ClusterWorkflowTemplate`; Tarot-composed readings are namespaced.

A `workflow-trigger` subscribes that reading to an infrastructure-owned
Sensor:

```yaml
appendix:
  lexicon:
    organization-ci-push:
      type: workflow-trigger
      sensorSelector: {source: forgejo, purpose: workflow-execution}
      readingSelector: {process: ci, profile: standard, version: v1}
      parameters:
        repository:
          from: body.repository.ssh_url
```

The Sensor performs the inverse `sensorSelector` lookup while it renders and
then resolves `readingSelector` exactly. Librarian only consolidates and
delivers these references.

## Patterns of Location

You can register lexicon entries at four levels. The recommended pattern is spell-level `appendix`, where the entry lives next to the resource that creates the infrastructure.

### 1. Spell Appendix (Recommended)

Register the lexicon entry in the same spell that deploys the infrastructure. This co-locates the registration with the resource.

```yaml
# bookrack/production/infrastructure/gateway.yaml
name: external-gateway
repository: https://github.com/istio/istio.git
path: manifests/charts/gateways/istio-ingress
revision: 1.23.0
namespace: istio-system

values:
  gateways:
    istio-ingressgateway:
      name: istio-external

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

The entry is visible to all spells in the book. When you delete the gateway spell, the lexicon entry goes with it.

### 2. Book-Level Appendix (Global)

Register entries in the book `index.yaml`. Use this for infrastructure that is not deployed by a spell in this bookrack, such as a shared Vault server managed externally.

```yaml
# bookrack/production/index.yaml
name: production

chapters:
  - infrastructure
  - applications

appendix:
  lexicon:
    production-vault:
      type: vault
      labels:
        environment: production
        default: book
      url: https://vault.production.svc:8200
      namespace: vault
      authPath: k8s-auth
      secretPath: kv
```

### 3. Chapter-Level Appendix (Chapter-Specific)

Register entries in a chapter `index.yaml` using `appendix` for book-wide visibility or `localAppendix` for chapter-only visibility.

```yaml
# bookrack/production/applications/index.yaml
name: applications

# Visible to all spells in the book
appendix:
  lexicon:
    app-database:
      type: database
      labels:
        engine: postgres
        default: book
      host: postgres-rw.databases.svc
      port: 5432

# Only visible to spells in this chapter
localAppendix:
  lexicon:
    app-gateway-override:
      type: istio-gw
      labels:
        access: external
      gateway: istio-system/app-specific-gateway
      baseURL: apps.example.com
```

| Scope | Field | Visibility |
|-------|-------|------------|
| `appendix` | `appendix.lexicon` | All spells in the book |
| `localAppendix` | `localAppendix.lexicon` | Only spells in this chapter |

## Default Resolution

When a glyph uses a `selector` and no exact match is found, the Runic Indexer falls back to defaults. The priority order is:

```
1. Exact match       -- selector labels match entry labels (AND logic)
2. Chapter default   -- entry with label default: chapter in the same chapter
3. Book default      -- entry with label default: book
```

### Setting a Book Default

Add `default: book` to the entry labels. When no selector matches, this entry is used as the fallback for the entire book.

```yaml
appendix:
  lexicon:
    main-gateway:
      type: istio-gw
      labels:
        access: external
        default: book             # Fallback for any istio-gw lookup
      gateway: istio-system/main-gateway
      baseURL: example.com
```

### Setting a Chapter Default

Add `default: chapter` to the entry labels and set the `chapter` field to the chapter name. This entry is the fallback only for spells in that specific chapter.

```yaml
appendix:
  lexicon:
    chapter-gateway:
      type: istio-gw
      labels:
        access: public
        default: chapter          # Fallback only for this chapter
      chapter: production         # Must match the chapter name
      gateway: istio-system/chapter-gateway
      baseURL: chapter.example.com
```

### Resolution Example

Given this lexicon:

```yaml
lexicon:
  book-gateway:
    type: istio-gw
    labels:
      access: public
      default: book
    gateway: istio-system/book-gw
    baseURL: book.example.com

  chapter-gateway:
    type: istio-gw
    labels:
      access: public
      default: chapter
    chapter: staging
    gateway: istio-system/chapter-gw
    baseURL: chapter.example.com

  private-gateway:
    type: istio-gw
    labels:
      access: private
    gateway: istio-system/private-gw
    baseURL: private.example.com
```

| Selector | Chapter | Result | Reason |
|----------|---------|--------|--------|
| `access: private` | any | `private-gateway` | Exact match |
| `access: unknown` | staging | `chapter-gateway` | No exact match; chapter default for "staging" |
| `access: unknown` | production | `book-gateway` | No exact match; no chapter default for "production"; book default |
| (empty) | staging | `chapter-gateway` | Empty selector triggers default fallback |

An empty selector never matches any entry directly. It always falls through to the default resolution chain.

## Environment Portability

The lexicon is how Runik Platform achieves environment portability. You write each spell once and deploy it to any book. Each book provides its own lexicon entries for the infrastructure in that environment.

```
bookrack/
  staging/
    index.yaml                     # appendix.lexicon: vault -> staging vault
    infrastructure/
      gateway.yaml                 # appendix.lexicon: istio-gw -> staging gateway
    applications/
      api-service.yaml             # selector: {access: external} -- same spell
      frontend.yaml                # selector: {access: external} -- same spell

  production/
    index.yaml                     # appendix.lexicon: vault -> production vault
    infrastructure/
      gateway.yaml                 # appendix.lexicon: istio-gw -> production gateway
    applications/
      api-service.yaml             # selector: {access: external} -- identical spell
      frontend.yaml                # selector: {access: external} -- identical spell
```

The application spells in both books can be identical. The only differences are the lexicon entries registered by each book's infrastructure spells. When the istio glyph renders a VirtualService, it discovers the correct gateway and base URL for that environment automatically.

## Complete Example: Register a Gateway and Use It

### Step 1: Deploy the Gateway and Register It

```yaml
# bookrack/production/infrastructure/external-gateway.yaml
name: external-gateway
repository: 'https://github.com/istio/istio.git'
path: manifests/charts/gateways/istio-ingress
revision: 1.23.0
namespace: istio-system

values:
  gateways:
    istio-ingressgateway:
      name: istio-external
      labels:
        istio: external-gateway
      type: LoadBalancer
      ports:
        - port: 80
          targetPort: 8080
          name: http2
        - port: 443
          targetPort: 8443
          name: https

# Register in lexicon so other spells can discover it
appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: istio-system/external-gateway
      baseURL: example.com

# Create the Istio Gateway resource
glyphs:
  istio:
    external:
      type: istio-gw
      enabled: true
      hosts:
        - example.com
        - "*.example.com"
      istioSelector:
        istio: external-gateway
      name: external-gateway
      tls:
        enabled: true
        issuerName: default-issuer
      ports:
        - name: http
          port: 80
          protocol: HTTP
        - name: https
          port: 443
          protocol: HTTPS

  cert-manager:
    external-cert:
      type: certificate
      enabled: true
      dnsNames:
        - example.com
        - "*.example.com"
```

### Step 2: Use the Gateway from an Application Spell

```yaml
# bookrack/production/applications/api-service.yaml
name: api-service
image: myorg/api:v1.0

service:
  enabled: true
  ports:
    - port: 8080
      name: http

istio:
  api-route:
    type: virtualService
    selector:
      access: external           # Finds external-gateway from lexicon
    subdomain: api
    httpRules:
      - prefix: /
        port: 8080
```

At render time, the istio glyph finds the `external-gateway` lexicon entry (type `istio-gw`, label `access: external`) and generates:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-service-external-gateway
spec:
  hosts:
    - api.example.com              # subdomain + baseURL from lexicon
  gateways:
    - istio-system/external-gateway # gateway from lexicon
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: api-service.applications.svc.cluster.local
            port:
              number: 8080
```

No hard-coded gateway. No hard-coded domain. If you deploy the same spell in a staging book that registers its own `external-gateway` lexicon entry with `baseURL: staging.example.com`, the VirtualService automatically uses the staging domain.

## Appendix Collection Process

The librarian uses a two-pass system to collect all lexicon entries before generating any ArgoCD Applications:

**Pass 1** -- Collect all `appendix.lexicon` entries from:
1. Book `index.yaml`
2. Chapter `index.yaml` files
3. Every spell file in every chapter

All entries are merged into a single global lexicon dictionary using `mergeOverwrite`. Later entries with the same name override earlier ones.

**Pass 2** -- For each spell, build the final lexicon:
1. Start with the global lexicon from Pass 1
2. Override with `localAppendix.lexicon` from the chapter `index.yaml`
3. Override with `localAppendix.lexicon` from the spell file itself
4. Pass the final lexicon to all chart sources

This means a spell's `appendix.lexicon` entries are visible to every other spell in the book, while `localAppendix.lexicon` entries are scoped to the chapter or spell that defines them.

## Cross-References

- [spells.md](spells.md) -- Spell anatomy, including `appendix` and `localAppendix` fields
- [bookrack.md](bookrack.md) -- Book and chapter structure, configuration merging
- [glyphs.md](glyphs.md) -- Glyph types that consume lexicon entries (istio, vault, cert-manager)
- [platform-patterns.md](platform-patterns.md) -- Multi-environment and multi-tenant patterns using lexicon
- [../design/lexicon.md](../design/lexicon.md) -- Internal design of the Runic Indexer and selection algorithm
