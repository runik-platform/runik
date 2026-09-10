# Glyphs

## What is a Glyph?

```yaml
glyphs:
  vault:
    db-credentials:
      type: secret
      format: env
      randomKeys:
        - password
      staticData:
        username: api_service
```

A **glyph** is a declarative infrastructure component that you add to a spell. Instead of writing raw Kubernetes YAML for a VaultSecret, VirtualService, Certificate, or PostgreSQL Cluster, you declare what you need in a few lines and the responsible dispatcher renders the underlying resources.

Runik has two dispatchers that can process glyphs, and the one that runs depends on the spell's primary source (see [Two Dispatchers, Two YAML Locations](#two-dispatchers-two-yaml-locations) below):

- **Summon's internal dispatcher** — when the primary source is summon (no `chart:` / `path:`), glyphs appear as top-level keys of the spell and render inline in the summon output.
- **Kaster** — when the primary source is an external chart (`chart:` / `path:`), glyphs go under the `glyphs:` key and the Librarian emits a separate ArgoCD source pointing to kaster.

Both dispatchers iterate the glyph subcharts (vault, istio, cert-manager, etc.) and call the template matching the glyph's `type` field — the naming convention and signature are identical, so a single glyph template works from either dispatcher.

Each glyph entry follows this structure:

```yaml
glyphs:
  <subchart>:            # Which glyph subchart to use (vault, istio, etc.)
    <instance-name>:     # Unique name for this glyph instance
      type: <type>       # Which template to invoke in that subchart
      # ... type-specific fields
```

The `<instance-name>` becomes the `.name` field in the template context, used for naming the generated Kubernetes resources.

## The Problem Glyphs Solve

### Without Glyphs

To give an application access to a Vault secret, configure Istio routing, provision a TLS certificate, and create a PostgreSQL database, you write and maintain all of this separately:

```yaml
# vault-secret.yaml - 30+ lines
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: api-credentials
spec:
  refreshPeriod: 3m0s
  vaultSecretDefinitions:
    - name: secret
      requestType: GET
      path: kv/data/production/apps/publics/api-credentials
      authentication:
        path: production
        role: api-service
        serviceAccount:
          name: api-service
      connection:
        address: https://vault.vault.svc:8200
        tLSConfig:
          skipVerify: false
  output:
    name: api-credentials
    stringData:
      DATABASE_URL: '{{ .secret.database-url }}'
      API_KEY: '{{ .secret.api-key }}'
    type: Opaque
---
# vault-policy.yaml - 40+ lines
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Policy
metadata:
  name: api-service
  namespace: vault
spec:
  authentication: ...
  connection: ...
  policy: |
    path "kv/data/production/apps/api-service/*" { ... }
    path "kv/data/production/publics/*" { ... }
---
# vault-role.yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: KubernetesAuthEngineRole
metadata:
  name: api-service
  namespace: vault
spec: ...
---
# virtual-service.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-service
spec:
  hosts: ["api.example.com"]
  gateways: ["istio-system/external-gateway"]
  http:
    - match: [{ uri: { prefix: /api } }]
      route:
        - destination:
            host: api-service.apps.svc.cluster.local
            port: { number: 8080 }
---
# certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-cert
spec:
  dnsNames: ["api.example.com"]
  issuerRef: { name: letsencrypt-prod, kind: ClusterIssuer }
  secretName: api-cert
---
# postgresql.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: api-db
spec:
  instances: 2
  bootstrap:
    initdb:
      database: api_service
      owner: api_service
      secret: { name: api-db-credentials }
  storage: { size: 10Gi }
```

That is 6+ files, 150+ lines of YAML, with hardcoded Vault paths, connection details, and cluster addresses scattered throughout. Every environment needs a separate copy.

### With Glyphs

The same infrastructure, declared once in your spell:

```yaml
name: api-service
namespace: apps
image: myorg/api:v1.0

service:
  enabled: true
  ports:
    - port: 8080
      name: http

glyphs:
  vault:
    prolicy:
      type: prolicy

    api-credentials:
      type: secret
      format: env
      keys:
        - database-url
        - api-key

  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external

  cert-manager:
    api-cert:
      type: certificate
      dnsNames:
        - api.example.com

  postgresql:
    api-db:
      type: cluster
      dbName: api_service
      userName: api_service
      secret: api-db-credentials
      instances: 2
      storage:
        size: 10Gi
```

One file. Environment-specific details (Vault address, gateway URL, issuer name) are resolved dynamically via the lexicon. The same spell works in production and staging without modification.

## Two Dispatchers, Two YAML Locations

Runik has two independent glyph dispatchers. The dispatcher a spell uses is determined mechanically by whether the spell has `chart:` / `path:`, and the infrastructure goes in a different location of the YAML accordingly. See also [root CLAUDE.md §4](../../CLAUDE.md) for the framework-level view.

### Spells that use summon — top-level keys

When a spell has no `chart:` and no `path:`, the primary source is summon (the `defaultTrinket`). Summon ships its own internal glyph dispatcher that iterates its subcharts and triggers on **subchart names used as top-level keys of the spell**:

```yaml
name: my-app
image: myorg/app:v1.0

vault:                      # <-- top-level key, handled by summon inline
  my-secret:
    type: secret
    keys: [api-key]
istio:                      # <-- top-level key, handled by summon inline
  route:
    type: virtualService
    enabled: true
```

No `glyphs:` wrapper, no kaster source. The resources are rendered inside the summon source. Infrastructure-only spells follow the same pattern: set `workload.enabled: false` to suppress the Deployment while summon still renders the top-level infrastructure keys.

```yaml
name: tls-certificates
namespace: cert-manager

workload:
  enabled: false

cert-manager:
  wildcard:
    type: certificate
    dnsNames:
      - "*.example.com"
```

**Result**: one ArgoCD Application with one source (summon). Summon's internal dispatcher renders the Certificate. No kaster source is emitted.

### Spells that use an external chart — under `glyphs:`

When a spell has `chart:` or `path:`, summon does not run. Infrastructure goes under the `glyphs:` key so that the top-level kaster dispatcher picks it up as a separate ArgoCD source:

```yaml
name: nginx
repository: https://charts.bitnami.com/bitnami
chart: nginx
revision: 18.2.6
namespace: web

values:
  replicaCount: 2

glyphs:
  istio:
    nginx-route:
      type: virtualService
      enabled: true
      selector:
        access: external
  cert-manager:
    nginx-cert:
      type: certificate
      dnsNames:
        - nginx.example.com
```

The `glyphs:` key is registered as the trigger for the kaster trinket in the book's `index.yaml`:

```yaml
# book index.yaml
trinkets:
  kaster:
    key: glyphs
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: upstream
```

The Librarian routes the contents under `glyphs:` to its own kaster source and does not forward them to the external chart (which would not know how to read them).

**Result**: ArgoCD Application with 2 sources — bitnami/nginx (Deployment, Service) and kaster (VirtualService, Certificate).

### Same dispatch convention in both cases

Both dispatchers use the same naming convention (`<chart>.<type>`) and the same lexicon. Only the YAML location of the infrastructure block differs — top-level when summon is primary, under `glyphs:` when an external chart is primary.

## Vault Glyph

The vault glyph integrates with HashiCorp Vault via the vault-config-operator CRDs. Policy and Kubernetes authentication roles can be rendered independently, while the legacy `prolicy` type remains as a compatibility metaglyph that renders both.

### type: secret

```yaml
glyphs:
  vault:
    api-credentials:
      type: secret
      path: chapter
      format: env
      keys:
        - database-url
        - api-key
      staticData:
        environment: production
      randomKeys:
        - password
      passPolicyName: simple-password-policy
      secretType: Opaque
      refreshPeriod: 3m0s
```

Generates a **VaultSecret** that syncs a secret from Vault into a Kubernetes Secret. When `randomKeys` or `random: true` is specified, also generates **RandomSecret** resources that create random values in Vault.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | `"summon"` | Path resolution mode. `"book"` = `/{book}/publics/{name}`. `"chapter"` = `/{book}/{chapter}/publics/{name}`. `"summon"` = `/{book}/{chapter}/{namespace}/publics/{name}`. `"/absolute/path"` = literal path. |
| `format` | string | `"plain"` | Output format. `"env"` = uppercase keys with `_` replacing `-`. `"plain"` = keys as-is. `"json"` = single key with JSON value. `"b64"` = base64-encoded. `"yaml"` = YAML-encoded. |
| `keys` | list | required for `plain`/`env` Vault reads | Vault secret keys to include in the Kubernetes Secret. |
| `staticData` | map | `{}` | Static key-value pairs added directly to the Secret (not from Vault). |
| `random` | bool | `false` | Generate a random `password` key in Vault. |
| `randomKey` | string | - | Generate a single random key with a custom name. |
| `randomKeys` | list | `[]` | Generate multiple random keys, each as a separate RandomSecret. |
| `passPolicyName` | string | `"simple-password-policy"` | Vault password policy for random secret generation. |
| `secretType` | string | `"Opaque"` | Kubernetes Secret type (e.g., `kubernetes.io/tls`, `kubernetes.io/basic-auth`). |
| `refreshPeriod` | string | `"3m0s"` | How often the operator re-syncs the secret from Vault. |
| `serviceAccount` | string | spell name | ServiceAccount used for Vault authentication. |
| `customRole` | string | - | Override the Vault role (default: derived from serviceAccount). |
| `nameOverwrite` | string | glyph name | Override the output Secret name. |
| `namespace` | string | release namespace | Override the namespace for the generated Secret. |
| `generationType` | string | `"kv"` | `"kv"` for KV v2 secrets, `"database"` for dynamic database credentials, or `"database-static"` for a stable database identity. |
| `databaseEngine` | string | - | Required when `generationType: database`. Name of the database engine in lexicon. |
| `databaseRole` | string | - | Required when `generationType: database`. `"read-write"` or `"read-only"`. |
| `databaseCredsName` | string | - | Exact Vault role name. Required for `generationType: database-static`; also overrides the derived role name for dynamic credentials. |
| `labels` | map | `{}` | Additional labels on the VaultSecret and output Secret. |
| `annotations` | map | `{}` | Additional annotations on the VaultSecret and output Secret. |

For `plain` and `env`, declare `keys` whenever the output reads existing values
from Vault. `keys` is not needed when the output is composed entirely from
`staticData`, `templateData`, `random`, `randomKey`, or `randomKeys`. The
aggregate formats (`json`, `yaml`, and `b64`) serialize the complete Vault value
under their configured output key and therefore do not enumerate `keys`.

**Path resolution examples** (assuming book=`production`, chapter=`apps`, namespace=`api-service`, secretPath=`kv`):

| `path` Value | Resolved Vault Path |
|--------------|---------------------|
| `"book"` | `kv/data/production/publics/api-credentials` |
| `"chapter"` | `kv/data/production/apps/publics/api-credentials` |
| `"summon"` (default) | `kv/data/production/apps/api-service/publics/api-credentials` |
| `"/shared/creds"` | `kv/data/shared/creds/api-credentials` |

**Format comparison**:

```yaml
# format: env -- keys uppercased, dashes become underscores
DATABASE_URL: '{{ .secret.database-url }}'
API_KEY: '{{ .secret.api-key }}'

# format: plain -- keys as-is
database-url: '{{ .secret.database-url }}'
api-key: '{{ .secret.api-key }}'

# format: json -- single key with full JSON
config-json: '{{ .secret | toJson }}'

# format: b64 -- base64 encoded
encoded-data: '{{ .secret.b64 }}'

# format: yaml -- YAML encoded
config-yaml: '{{ .secret | toYaml }}'
```

**Dynamic database credentials**:

```yaml
glyphs:
  vault:
    db-creds:
      type: secret
      generationType: database
      databaseEngine: postgres
      databaseRole: read-write
      format: env
      keys:
        - username
        - password
```

This generates a VaultSecret that reads from the Vault database secrets engine path `database-{book}-{chapter}/creds/{engine}-{role}`.

**Static database identity**:

```yaml
glyphs:
  vault:
    db-creds:
      type: secret
      generationType: database-static
      databaseCredsName: postgres-myapp
      format: env
      keys:
        - username
        - password
```

This reads the current credential for a `DatabaseSecretEngineStaticRole` from
`database/static-creds/postgres-myapp`. The username remains stable while Vault
rotates its password according to the static role's rotation period.

### type: policy

```yaml
glyphs:
  vault:
    app-policy:
      type: policy
      nameOverride: api-service
      paths:
        - path: "transit/encrypt/my-key"
          capabilities: ["update"]
        - path: "transit/decrypt/my-key"
          capabilities: ["update"]
```

Generates only a Vault **Policy** from the explicitly declared rules. It does not add application-private, publics, pipeline, password-policy, database, lexicon, book, or chapter paths. Use `prolicy` when those Runik conventions are desired.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `selector` | map | `{provider: operator}` | Additional lexicon selectors for the target Vault secret store. |
| `nameOverride` | string | spell name | Policy resource name. Reference this value from a separate role's `policies` list. |
| `paths` | list | required | Policy rules. Each entry requires `path` and `capabilities`. |
| `labels` | map | `{}` | Additional labels on the Policy. |
| `annotations` | map | `{}` | Additional annotations on the Policy. |

### type: role

```yaml
glyphs:
  vault:
    app-role:
      type: role
      nameOverride: api-service-role
      policies:
        - api-service
      serviceAccount: api-service
      tokenPeriod: 3600
```

Generates only a **KubernetesAuthEngineRole**. Use `policies` to bind it to one or more separately managed Vault policies. If omitted, it references a policy with the same name as the role for concise one-to-one declarations.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `selector` | map | `{provider: operator}` | Additional lexicon selectors for the target Vault secret store. |
| `nameOverride` | string | spell name | Role resource name. |
| `policies` | list | resolved role name | Vault policies attached to the role. |
| `serviceAccount` | string | spell name | Kubernetes ServiceAccount bound to the Vault role. |
| `targetNamespace` | string | release namespace | Namespace containing the target ServiceAccount. |
| `tokenPeriod` | integer | unset | Periodic token duration in seconds. When unset, Vault's normal TTL and max TTL apply. |
| `labels` | map | `{}` | Additional labels on the KubernetesAuthEngineRole. |
| `annotations` | map | `{}` | Additional annotations on the KubernetesAuthEngineRole. |

### type: prolicy

```yaml
glyphs:
  vault:
    prolicy:
      type: prolicy
      serviceAccount: api-service
      bookPublicsWrite: false
      chapterPublicsWrite: true
      extraPolicy:
        - path: "transit/encrypt/my-key"
          capabilities: ["update"]
```

Opinionated, backward-compatible metaglyph that builds Runik's standard application-private, publics, pipeline, password-policy and database paths, then composes `vault.policy` and `vault.role`. It generates the same **Policy** and **KubernetesAuthEngineRole**, with the same input signature and defaults as before the glyphs were split.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `serviceAccount` | string | spell name | ServiceAccount to bind to the Vault role. |
| `nameOverride` | string | spell name | Override the policy and role name. |
| `selector` | map | `{provider: operator}` | Additional lexicon selectors forwarded to both component glyphs. |
| `bookPublicsWrite` | bool | `false` | Grant write access to `{book}/publics/*` (default: read-only). |
| `chapterPublicsWrite` | bool | `false` | Grant write access to `{book}/{chapter}/publics/*` (default: read-only). |
| `extraPolicy` | list | `[]` | Additional Vault policy paths with custom capabilities. |
| `targetNamespace` | string | release namespace | Namespace/path override forwarded to both component glyphs. |
| `tokenPeriod` | integer | unset | Periodic token duration in seconds, forwarded to `role`. |
| `labels` | map | `{}` | Additional labels forwarded to both component glyphs. |
| `annotations` | map | `{}` | Additional annotations forwarded to both component glyphs. |

**Default permissions generated**:

| Path Pattern | Capabilities |
|-------------|-------------|
| `{secretPath}/data/{book}/{chapter}/{namespace}/*` | create, read, update, delete, list |
| `{secretPath}/data/{book}/{chapter}/publics/*` | read, list (or full CRUD if `chapterPublicsWrite: true`) |
| `{secretPath}/data/{book}/publics/*` | read, list (or full CRUD if `bookPublicsWrite: true`) |
| `{secretPath}/data/{book}/pipelines/*` | read, list |
| `sys/policies/password/*` | read, list |
| `database-{book}-{chapter}/creds/*` | read (auto-added when postgres/mongodb in lexicon) |

### type: kubeAuth

```yaml
glyphs:
  vault:
    cluster-auth:
      type: kubeAuth
      clusterSelector:
        name: dev-cluster
      createRemoteRBAC: true
```

Generates an **AuthEngineMount**, **KubernetesAuthEngineConfig**, and **KubernetesAuthEngineRole**. Use this to configure Vault's Kubernetes authentication method for a remote cluster.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `clusterSelector` | map | required | Selector to find the target Kubernetes cluster in the lexicon (type `k8s`). |
| `createRemoteRBAC` | bool | `false` | Create ServiceAccount, ClusterRole, and ClusterRoleBinding for the `vault-token-reviewer` in the remote cluster. |

### type: customPasswordPolicy

```yaml
glyphs:
  vault:
    strong-policy:
      type: customPasswordPolicy
      policy: |
        length = 30
        rule "charset" {
          charset = "abcdefghijklmnopqrstuvwxyz"
          min-chars = 5
        }
        rule "charset" {
          charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          min-chars = 5
        }
        rule "charset" {
          charset = "0123456789"
          min-chars = 5
        }
```

Generates a **PasswordPolicy** in Vault. You can then reference this policy by name in secret glyphs via `passPolicyName`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `policy` | string or map | required | The password policy definition in HCL format (string) or structured map format. |

### type: databaseEngine

```yaml
glyphs:
  vault:
    db-engine:
      type: databaseEngine
      postgresSelector:
        app: my-postgres
```

Generates a **DatabaseSecretEngineConfig** plus **DatabaseSecretEngineRole** resources (both `read-write` and `read-only` roles). This configures Vault to issue dynamic database credentials for a PostgreSQL instance discovered via the lexicon.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `postgresSelector` | map | required | Selector to find the PostgreSQL server in the lexicon (type `postgres`). |
| `databaseMount` | string | `database-{book}-{chapter}` | Override the Vault database engine mount path. |

The PostgreSQL entry in the lexicon must provide `host`, `port`, `database`, and either `credentialsSecret` (K8s Secret name) or `vaultSecretPath` (Vault path containing root credentials).

### type: cryptoKey

```yaml
glyphs:
  vault:
    dkim-key:
      type: cryptoKey
      algorithm: ed25519
      domain: example.com
      comment: "DKIM signing key"
```

Generates a **Job** that creates an Ed25519 or RSA keypair, stores it in Vault, and a **VaultSecret** that syncs the keypair to a Kubernetes Secret.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `algorithm` | string | `"ed25519"` | Key algorithm: `"ed25519"` or `"rsa"`. |
| `bits` | int | `4096` | RSA key size (only used when `algorithm: rsa`). |
| `domain` | string | - | Optional domain annotation stored alongside the key. |
| `comment` | string | `{name}@{namespace}` | SSH key comment. |

The generated Kubernetes Secret contains: `private_key`, `public_key`, `public_key_base64`, `algorithm`, and optionally `domain`.

## Istio Glyph

The istio glyph generates Istio networking resources. It supports two types.

### type: virtualService

```yaml
glyphs:
  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external
      subdomain: api
      httpRules:
        - prefix: /v1
          port: 8080
        - prefix: /v2
          host: api-v2.apps.svc.cluster.local
          port: 8080
```

Generates an Istio **VirtualService**. The `selector` field queries the lexicon for gateways of type `istio-gw`. For each matching gateway, a separate VirtualService is created (the resource name is `{name}-{gateway-name}`).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | required | Must be `true` to generate the resource. |
| `selector` | map | `{}` | Lexicon selector to find gateways (type `istio-gw`). Example: `{access: external}`. |
| `subdomain` | string | inherited | Subdomain prepended to the gateway's `baseURL`. Inherits from chapter or book if not set. |
| `httpRules` | list | auto-generated | HTTP routing rules. Each rule has `prefix`, `rewrite`, `host`, and `port`. |
| `tcpRules` | list | - | TCP routing rules. Each rule has `port`, `incomingPort`, and `host`. |
| `prefix` | string | `/{name}` | Default URL prefix for the auto-generated rule (when `httpRules` is not set). |
| `rewrite` | string | `"/"` | URL rewrite target for the auto-generated rule. |
| `host` | string | `{name}.{namespace}.svc.cluster.local` | Default destination host. |
| `nameOverride` | string | - | Override the resource name. |
| `namespace` | string | release namespace | Override the namespace. |

When you omit `httpRules`, kaster auto-generates a single HTTP rule using `prefix` and `rewrite`:

```yaml
# This minimal config:
glyphs:
  istio:
    api:
      type: virtualService
      enabled: true
      selector:
        access: external

# Generates a VirtualService with:
#   match: prefix: /api-service (derived from spell name)
#   rewrite: /
#   destination: api-service.{namespace}.svc.cluster.local:80
```

### type: istio-gw

```yaml
glyphs:
  istio:
    external:
      type: istio-gw
      hosts:
        - "*.example.com"
        - example.com
      istioSelector:
        istio: external-gateway
      tls:
        enabled: true
        issuerName: external-cert
      ports:
        - name: http
          port: 80
          protocol: HTTP
        - name: https
          port: 443
          protocol: HTTPS
```

Generates an Istio **Gateway** resource. You typically create gateways in an infrastructure chapter and register them in the lexicon so that virtualService glyphs can discover them.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `hosts` | list | required | Hostnames the gateway serves. |
| `istioSelector` | map | `{istio: {name}}` | Pod selector to target the Istio ingress deployment. |
| `tls.enabled` | bool | `true` | Enable TLS. When true, HTTPS port gets `SIMPLE` mode with credential, HTTP port gets `httpsRedirect`. |
| `tls.secretName` | string | `{name}-{issuerName}-cert` | TLS credential name (must match a Certificate secret). |
| `tls.issuerName` | string | - | Used to derive the default `secretName`. |
| `ports` | list | `[{http:80}, {https:443}]` | Server port definitions with `name`, `port`, and `protocol`. |
| `annotations` | map | `{}` | Additional annotations. |

**Registering a gateway in the lexicon** so other spells can route through it:

```yaml
name: external-gateway
namespace: istio-system

appendix:
  lexicon:
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: istio-system/external-gateway
      baseURL: example.com

glyphs:
  istio:
    external:
      type: istio-gw
      hosts:
        - "*.example.com"
      istioSelector:
        istio: external-gateway
```

## CertManager Glyph

The cert-manager glyph integrates with cert-manager for TLS certificate lifecycle management. It supports five types.

> **Deprecated:** the legacy `certManager:` key remains accepted for existing
> books, but new spells must use `cert-manager:`. See [Deprecations and
> Compatibility Window](deprecations.md).

### type: certificate

```yaml
glyphs:
  cert-manager:
    wildcard:
      type: certificate
      dnsNames:
        - "*.example.com"
        - example.com
```

Generates a cert-manager **Certificate**. The glyph uses the lexicon to discover ClusterIssuers (type `cert-issuer`). For each matching issuer, a separate Certificate is created.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dnsNames` | list | required | DNS names for the certificate. The first entry becomes the `commonName`. |
| `selector` | map | `{}` | Lexicon selector to find issuers (type `cert-issuer`). |
| `name` | string | spell name | Name component. Generated resource name: `{name}-{issuer}-cert`. |
| `labels` | map | `{}` | Additional labels. |
| `annotations` | map | `{}` | Additional annotations. |

The generated Secret name follows the pattern `{spell-name}-{glyph-name}-cert`.

### type: clusterIssuer

```yaml
glyphs:
  cert-manager:
    letsencrypt:
      type: clusterIssuer
      issuerType: cloudflare
      email: admin@example.com
```

Generates a cert-manager **ClusterIssuer** configured for ACME DNS-01 challenges.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `issuerType` | string | required | DNS provider: `"linode"`, `"gcp"`, `"cloudflare"`, or `"aws"`. |
| `email` | string | required | ACME account email. |
| `linode.apiKey` | string | - | Direct API key (or use `linode.secret`). |
| `linode.secret.name` | string | - | K8s Secret name containing the Linode API key. |
| `linode.secret.key` | string | - | Key within the Secret. |
| `gcp.projectID` | string | - | GCP project ID. |
| `gcp.secret.name` | string | - | K8s Secret for GCP service account key. |
| `cloudflare.secret.name` | string | `"cloudflare"` | K8s Secret name for Cloudflare API token. |
| `cloudflare.secret.key` | string | `"api-token"` | Key within the Secret. |
| `aws.region` | string | `"us-east-1"` | AWS region. |
| `aws.hostedZoneID` | string | - | Route53 hosted zone ID. |
| `aws.role` | string | - | IAM role ARN. |
| `aws.accessKeyID` | string | - | AWS access key (or use IRSA). |
| `aws.secret.name` | string | - | K8s Secret for AWS secret access key. |

**Example with different DNS providers**:

```yaml
# Cloudflare
glyphs:
  cert-manager:
    issuer:
      type: clusterIssuer
      issuerType: cloudflare
      email: admin@example.com
      cloudflare:
        secret:
          name: cloudflare-api
          key: api-token

# AWS Route53
glyphs:
  cert-manager:
    issuer:
      type: clusterIssuer
      issuerType: aws
      email: admin@example.com
      aws:
        region: us-east-1
        hostedZoneID: Z1234567890
        role: arn:aws:iam::123456789:role/cert-manager
```

### type: dnsEndpoint

```yaml
glyphs:
  cert-manager:
    service-a:
      type: dnsEndpoint
      dnsName: "service-a.int.example.com"
      target: "10.42.0.100"
      recordType: A
```

Generates an **DNSEndpoint** (external-dns CRD) for static DNS records.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dnsName` | string | required | The DNS record name. |
| `target` | string | required | The DNS record target (IP address or hostname). |
| `recordType` | string | `"A"` | DNS record type (A, CNAME, TXT, etc.). |

### type: dnsEndpointSourced

```yaml
glyphs:
  cert-manager:
    dkim-record:
      type: dnsEndpointSourced
      dnsName: "default._domainkey.example.com"
      recordType: TXT
      sourceSecret: dkim-key
      sourceKey: public_key_base64
      dnsRecordFormat: "v=DKIM1; k=ed25519; p=%s"
```

Generates a **DNSEndpoint** plus a **Job** that reads a value from a Kubernetes Secret (typically synced from Vault) and patches the DNSEndpoint with the actual value. Use this when DNS record values come from dynamically generated secrets (e.g., DKIM keys stored in Vault).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dnsName` | string | required | The DNS record name. |
| `sourceSecret` | string | required | Name of the K8s Secret to read. |
| `sourceKey` | string | required | Key within the Secret. |
| `dnsRecordFormat` | string | - | Optional `printf` format string applied to the value. |
| `recordType` | string | `"TXT"` | DNS record type. |

## MongoDB Glyph

The MongoDB glyph combines Percona's physical cluster and backup lifecycle with
the generic MongoDB operations controller. Each application receives a logical
database and a stable, database-scoped user. Collections remain an application
concern and are created on first use.

### type: cluster

```yaml
glyphs:
  mongodb:
    mongo-main:
      type: cluster
      namespace: databases
      storage:
        size: 20Gi
        storageClassName: longhorn
      operations:
        allowedNamespaces:
          matchLabels:
            mongodb.runik.io/engine: mongo-main
```

The cluster must also publish a `type: mongodb` lexicon entry so consumers can
associate databases with its `engineName`. `operations` composes the
`MongoDBEngine`, one stable administrative Secret and the corresponding Percona
administrative user. `allowedNamespaces` is mandatory and never defaults to
cluster-wide access.

Backups remain owned by Percona. They are enabled by default and resolve the
book's default `s3-provider`. The default schedule is Sunday at 03:00
(`0 3 * * 0`); set `backup.enabled: false` when S3 is intentionally absent.

### type: engine

`engine` registers any MongoDB-compatible server independently of Percona:

```yaml
mongodb:
  shared:
    type: engine
    connection:
      host: mongodb.database-system.svc.cluster.local
      credentialsSecretRef:
        namespace: database-system
        name: mongodb-operator-admin
      tls:
        enabled: false
    allowedNamespaces:
      matchNames: [orders]
```

It only references credentials and TLS material. The operator and glyph have no
requirement that those Secrets come from Vault.

### type: database

`database` is the application-facing meta-glyph:

```yaml
mongodb:
  orders:
    type: database
    defaultUser:
      access: readWrite
```

The meta glyph creates `MongoDBDatabase`, a stable credential Secret and
`MongoDBUser`. `readWrite` is the default; the other presets are `readOnly`,
`schemaAdmin` and `owner`. `owner` includes MongoDB user administration and
should be exceptional.

The glyph key becomes the database, user and Secret name by default. The user is
created in that database and cannot request access to another one. Set
`defaultUser.enabled: false` when only the database claim is needed.

### type: user

```yaml
mongodb:
  reporting-reader:
    type: user
    databaseRef:
      name: reporting
    access: readOnly
    credentials:
      generate: false
    credentialsSecretRef:
      name: reporting-reader-mongodb
      usernameKey: username
      passwordKey: password
    credentialsRevision: "1"
```

`user` references one existing database and one Secret. By default it composes a
stable RandomSecret/VaultSecret; `credentials.generate: false` uses any external
Secret instead. Rotation is explicit: update the Secret first, then advance
`credentialsRevision`. For Vault-generated values, change
`credentials.generationRevision`, wait for the stable output Secret, and only
then advance `credentialsRevision`.

There is no `role` or collection type. Access presets belong to the user and
MongoDB materializes collections lazily.

### type: restore and type: instance

`restore` creates a `PerconaServerMongoDBRestore` from `backupName` or a native
`backupSource`. There is deliberately no on-demand backup glyph: recurring
backups belong to the cluster schedule.

The low-level `instance` type emits a raw `PerconaServerMongoDB` and makes the
caller responsible for the complete `spec`, including atomic role/user lists.

See [MongoDB glyph design](../design/mongodb-glyph.md) for the ownership model,
defaults, and lifecycle details.

## PostgreSQL Glyph

The postgresql glyph provisions CloudNativePG clusters.

### type: cluster

```yaml
glyphs:
  postgresql:
    api-db:
      type: cluster
      dbName: api_service
      userName: api_service
      secret: api-db-credentials
      instances: 2
      storage:
        size: 10Gi
        storageClass: fast-ssd
```

Generates a CloudNativePG **Cluster** resource.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dbName` | string | spell name | Database name to bootstrap. |
| `userName` | string | spell name | Database owner username. |
| `secret` | string | - | K8s Secret name containing bootstrap credentials. |
| `instances` | int | `1` | Number of PostgreSQL replicas. |
| `storage.size` | string | `"1Gi"` | PVC storage size. |
| `storage.storageClass` | string | - | StorageClass to use. |
| `description` | string | auto-generated | Cluster description. |
| `image` | map | - | Custom PostgreSQL image (`repository`, `name`, `tag`). |
| `superuserSecret` | string | - | Secret for the superuser password. |
| `superuser.enabled` | bool | `true` | Enable superuser access. |
| `primaryUpdateStrategy` | string | - | Update strategy (e.g., `unsupervised`). |
| `roles` | list | - | Managed PostgreSQL roles. |
| `resources` | map | - | CPU/memory resources. |
| `affinity` | map | - | Pod affinity/anti-affinity rules. |
| `postgresql` | map | - | PostgreSQL configuration parameters. |
| `postInitSQL` | map | - | SQL executed after init (outside transaction). `type: cm`, `create: true`, `content: "..."`. |
| `postInitApp` | map | - | Application SQL executed after init. Same structure as `postInitSQL`. |

**Full example with post-init SQL**:

```yaml
glyphs:
  postgresql:
    app-db:
      type: cluster
      dbName: myapp
      userName: myapp
      secret: myapp-db-creds
      instances: 3
      storage:
        size: 50Gi
        storageClass: ceph-block
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 4Gi
      postInitApp:
        type: cm
        create: true
        content: |
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
          CREATE EXTENSION IF NOT EXISTS "pgcrypto";
```

## Kafka Glyph

The `kafka` glyph emits Strimzi `kafka.strimzi.io/v1` resources. Install the
Strimzi Cluster Operator once at platform level; application and infrastructure
spells then use the glyph to declare clusters, topics, users, and related Kafka
components.

For a summon-based infrastructure spell, disable the default workload with
`workload.enabled: false`. Give Kafka resource Applications a sync wave after
the operator Application so that the CRDs exist before Argo CD applies the
custom resources.

### type: cluster

`cluster` is a meta-glyph that renders one `KafkaNodePool` for every entry in
`nodePools`, followed by one `Kafka` resource. Both `spec` blocks are native
Strimzi specs and are passed through unchanged.

```yaml
kafka:
  events:
    type: cluster
    nodePools:
      controllers:
        spec:
          replicas: 3
          roles: [controller]
          storage:
            type: persistent-claim
            size: 10Gi
      brokers:
        spec:
          replicas: 3
          roles: [broker]
          storage:
            type: persistent-claim
            size: 100Gi
    spec:
      kafka:
        version: 4.3.1
        metadataVersion: 4.3-IV0
        listeners:
          - {name: tls, port: 9093, type: internal, tls: true}
        config:
          offsets.topic.replication.factor: 3
          transaction.state.log.replication.factor: 3
          transaction.state.log.min.isr: 2
          default.replication.factor: 3
          min.insync.replicas: 2
      entityOperator:
        topicOperator: {}
        userOperator: {}
```

At least one node pool is required. Pool names default to
`<cluster-name>-<pool-key>` and every pool receives the required
`strimzi.io/cluster` label.

### type: topic and type: user

Topics and users accept `cluster` directly or resolve a `type: kafka` lexicon
entry through `selector`. Without either, the default selector is
`{default: book}`.

```yaml
appendix:
  lexicon:
    shared-events:
      type: kafka
      clusterName: events
      namespace: kafka
      bootstrapServers: events-kafka-bootstrap.kafka.svc:9093
      labels: {default: book}

kafka:
  audit-events:
    type: topic
    partitions: 12
    replicas: 3
    config:
      retention.ms: 604800000

  audit-writer:
    type: user
    authentication: {type: scram-sha-512}
    authorization:
      type: simple
      acls:
        - resource: {type: topic, name: audit-events, patternType: literal}
          operations: [Create, Describe, Write]
```

`topic` provides shorthand fields (`partitions`, `replicas`, `topicName`, and
`config`) and also accepts a complete `spec`. `user` provides shorthand for
`authentication`, `authorization`, `quotas`, and `template`, or a complete
`spec`.

### Other Kafka types

The remaining types use native Strimzi specs as a stable escape hatch:

| Type | Resource | Required relationship field |
|------|----------|-----------------------------|
| `nodePool` | `KafkaNodePool` | `cluster` or Kafka `selector` |
| `connect` | `KafkaConnect` | — |
| `connector` | `KafkaConnector` | `connectCluster` |
| `mirrorMaker2` | `KafkaMirrorMaker2` | — |
| `bridge` | `KafkaBridge` | — |
| `rebalance` | `KafkaRebalance` | `cluster` or Kafka `selector` |

All Kafka types accept `namespace`, `labels`, and `annotations`. The CRDs are
versioned with the Strimzi operator, so pin the operator chart and Kafka version
and review Strimzi upgrade notes before changing either.

## S3 Glyph

The s3 glyph provides S3-compatible object storage integration with automatic credential management via Vault and SeaweedFS.

### type: bucket

```yaml
glyphs:
  s3:
    uploads:
      type: bucket
      bucket: my-uploads
      permissions:
        - Read
        - Write
        - List
      pattern: true
```

Generates **VaultSecret** resources in both the application namespace (for app consumption) and the S3 provider namespace (for the aggregator to build S3 config). Credentials are auto-generated as RandomSecrets in Vault.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `bucket` | string | `{book}-{chapter}-{name}` | Bucket name. |
| `permissions` | list | `["Admin"]` | S3 permissions: `"Read"`, `"Write"`, `"List"`, `"Admin"`, etc. |
| `pattern` | bool or list | exact match | `true` = `{bucket}-*`. List = custom bucket patterns. `false`/omitted = exact bucket name. |
| `selector` | map | `{default: book}` | Lexicon selector to find the S3 provider (type `s3-provider`). |
| `passPolicyName` | string | `"short-policy"` | Vault password policy for credential generation. |

**Consuming S3 credentials in your application**:

The bucket glyph creates a Secret with keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT`, `AWS_REGION`, and `S3_BUCKET`. Reference it via `envFrom`:

```yaml
name: my-app
image: myorg/app:v1.0

glyphs:
  s3:
    data-store:
      type: bucket
      permissions: [Read, Write, List]

envFrom:
  - secretRef:
      name: data-store
```

### type: seaweed

```yaml
glyphs:
  s3:
    seaweedfs:
      type: seaweed
```

This is the infrastructure-side counterpart to `bucket`. Deploy it in the SeaweedFS namespace. It creates an **EventSource**, **Sensor**, aggregator **ConfigMap**, **ServiceAccount** + RBAC, and a Vault **prolicy**. When any `s3-identity` Secret changes, the aggregator Pod rebuilds the SeaweedFS S3 config, restarts the S3 gateway, and creates buckets.

You do not need to configure `seaweed` in application spells -- only in the SeaweedFS infrastructure spell.

### type: versity

```yaml
s3:
  gateway:
    type: versity
    trigger:
      type: workflow
      ttlStrategy:
        secondsAfterSuccess: 86400
        secondsAfterFailure: 604800
      podGC:
        strategy: OnWorkflowCompletion
        deleteDelayDuration: 30m
```

`versity` is the infrastructure-side provider metaglyph. It owns the
EventSource, Sensor, reconciliation script, RBAC, and backend-specific execution
shape required to synchronize S3 identity Secrets.

With `trigger.type: workflow`, the metaglyph uses the generic
`workflow.template` envelope to render `<name>-s3-reconcile`, then submits it
from its Sensor. The workflow spec remains private to the S3 metaglyph: it is
not a Tarot reading, default reading, or globally extensible process.

The internal Workflow uses the same bounded defaults shown above. The provider
spell may override `trigger.ttlStrategy` or `trigger.podGC` locally; these
operational settings do not publish or extend the private S3 process.

## Workflow Glyph

### type: template

The workflow glyph renders an already-resolved native Argo template. It owns
only the Kubernetes resource envelope and is reusable by Tarot, metaglyphs, or
direct spell declarations.

```yaml
workflow:
  reconcile-cache:
    type: template
    labels:
      process: cache-reconciliation
    spec:
      entrypoint: reconcile
      templates:
        - name: reconcile
          container:
            image: alpine:3.22
            command: [sh, -c]
            args: ["echo reconcile"]
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `spec` | map | required | Complete native Argo template spec |
| `namespace` | string | release namespace | Namespace for a namespaced template |
| `clusterScope` | bool | `false` | Render a `ClusterWorkflowTemplate` |
| `labels` | map | `{}` | Additional resource labels |
| `annotations` | map | `{}` | Resource annotations |

The entry key supplies the resource name. This glyph does not compose cards or
interpret process semantics.

## Argo Events workflow discovery

An infrastructure-owned `argo-events.sensor` may discover workflow
subscriptions from the lexicon. Give the Sensor stable labels and select its
EventSource:

```yaml
argo-events:
  workflow-sensor:
    type: sensor
    labels: {source: forgejo, purpose: workflow-execution}
    eventSourceSelector: {source: forgejo}
    requireWorkflowTriggers: true
    template:
      serviceAccountName: argo-eventbus
```

Workflow owners publish small references rather than new Sensors:

```yaml
appendix:
  lexicon:
    build-trigger:
      type: workflow-trigger
      sensorSelector: {source: forgejo, purpose: workflow-execution}
      readingSelector: {process: container-build, profile: standard, version: v1}
      filters:
        exprs:
          - expr: event_type == "push"
            fields:
              - name: event_type
                path: header.X-Gitea-Event.0
      parameters:
        repository:
          from: body.repository.ssh_url
```

While rendering, the Sensor finds every `workflow-trigger` whose
`sensorSelector` resolves to itself. Each publication becomes an isolated
dependency and trigger. `readingSelector` must resolve exactly one
`tarot-reading`; the Sensor validates and maps its declared inputs. Librarian
only supplies the consolidated lexicon.

## FreeForm Glyph

> **Deprecated:** the legacy `freeForm:` key remains accepted for existing
> books, but new spells must use `free-form:`. See [Deprecations and
> Compatibility Window](deprecations.md).

### type: manifest

```yaml
glyphs:
  free-form:
    custom-resource:
      type: manifest
      definition:
        apiVersion: example.com/v1
        kind: MyCustomResource
        metadata:
          name: my-resource
          namespace: default
        spec:
          replicas: 3
          config:
            key: value
```

Outputs the `definition` map as raw Kubernetes YAML. Use this as an escape hatch when no specialized glyph exists for the resource you need.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `definition` | map | required | Complete Kubernetes resource manifest. |

**Example: creating a NetworkPolicy**:

```yaml
glyphs:
  free-form:
    deny-all:
      type: manifest
      definition:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        metadata:
          name: deny-all
        spec:
          podSelector: {}
          policyTypes:
            - Ingress
            - Egress
```

## Available Glyphs Reference

| Glyph Key | Types | Description |
|-----------|-------|-------------|
| `vault` | `secret`, `policy`, `role`, `prolicy`, `kubeAuth`, `customPasswordPolicy`, `databaseEngine`, `cryptoKey` | HashiCorp Vault secrets, policies, auth, and crypto key management |
| `istio` | `virtualService`, `istio-gw` | Istio service mesh routing and gateway configuration |
| `cert-manager` | `certificate`, `clientCertificate`, `clusterIssuer`, `dnsEndpoint`, `dnsEndpointSourced` | TLS certificate lifecycle and DNS record management |
| `postgresql` | `cluster` | CloudNativePG PostgreSQL cluster provisioning |
| `kafka` | `cluster`, `nodePool`, `topic`, `user`, `connect`, `connector`, `mirrorMaker2`, `bridge`, `rebalance` | Strimzi-managed Kafka infrastructure and clients |
| `s3` | `bucket`, `seaweed`, `versity` | S3-compatible storage with automatic credential management |
| `workflow` | `template` | Native WorkflowTemplate resource envelope |
| `free-form` | `manifest` | Raw Kubernetes YAML escape hatch |
| `keycloak` | `client`, `clientScope`, `realm`, `clusterKeycloak`, `clusterRealm`, `flow`, `group`, `idp`, `realmRole`, `user` | Keycloak identity and access management |
| `argo-events` | `eventSource`, `sensor`, `eventBus` | Argo Events event-driven automation |
| `crossplane` | `provider` | Crossplane provider configuration |
| `aws` | IAM, RDS, S3, ACK | AWS resource management |
| `gcp` | DNS, GKE, IAM, KMS, Network, VMs, S3 | GCP resource management |
| `common` | labels, names, validation | Shared template helpers (used internally by other glyphs) |
| `runic-system` | `runic-indexer` | Internal lexicon indexing system |
| `summon` | `serviceAccount`, `service`, workload, storage | Workload resource generation (used internally by some glyphs) |
| `external-secrets` | external-secret, push-secret, secret-store | External Secrets Operator integration |

## Multi-Glyph Composition

The real power of glyphs is composing multiple infrastructure concerns in a single spell. Here is a production-ready application that combines vault, istio, cert-manager, postgresql, and s3:

```yaml
name: api-service
namespace: apps
image: myorg/api:v2.1.0

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
      name: http

resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 1Gi

probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
  readiness:
    httpGet:
      path: /ready
      port: 8080

envs:
  APP_ENV: production
  LOG_LEVEL: info

# All infrastructure declared together
glyphs:
  # --- Vault: authentication + secrets ---
  vault:
    # Vault policy + K8s auth role for this service
    prolicy:
      type: prolicy
      chapterPublicsWrite: true

    # Database credentials (random password, stored in Vault)
    db-credentials:
      type: secret
      format: env
      secretType: kubernetes.io/basic-auth
      randomKeys:
        - password
      staticData:
        username: api_service

    # Application secrets (JWT, API keys)
    app-secrets:
      type: secret
      format: env
      randomKeys:
        - JWT_SECRET
        - API_KEY
        - ENCRYPTION_KEY

  # --- Istio: traffic routing ---
  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external
      subdomain: api
      httpRules:
        - prefix: /v2
          port: 8080

  # --- Cert-Manager: TLS certificate ---
  cert-manager:
    api-cert:
      type: certificate
      dnsNames:
        - api.example.com

  # --- PostgreSQL: database cluster ---
  postgresql:
    api-db:
      type: cluster
      dbName: api_service
      userName: api_service
      secret: db-credentials
      instances: 2
      storage:
        size: 20Gi
      postInitApp:
        type: cm
        create: true
        content: |
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

  # --- S3: file storage ---
  s3:
    uploads:
      type: bucket
      permissions:
        - Read
        - Write
        - List

# Mount secrets as environment variables
envFrom:
  - secretRef:
      name: app-secrets
  - secretRef:
      name: db-credentials
  - secretRef:
      name: uploads
```

This single spell generates an ArgoCD Application with two sources:

- **Source 1 (summon)**: Deployment, Service, ServiceAccount
- **Source 2 (kaster)**: Policy, KubernetesAuthEngineRole, 2x RandomSecret, 2x VaultSecret, VirtualService, Certificate, PostgreSQL Cluster, S3 bucket credentials

All Vault paths, gateway URLs, issuer names, and S3 endpoints are resolved dynamically from the lexicon. Moving this spell to a different book (environment) requires zero changes to the spell itself -- only the lexicon entries differ.

## Cross-References

- [spells.md](spells.md) -- The 7 spell types and how glyphs fit into each
- [bookrack.md](bookrack.md) -- Configuration hierarchy, merging, and chapter ordering
- [lexicon.md](lexicon.md) -- How lexicon entries enable dynamic infrastructure discovery
- [summon.md](summon.md) -- Workload configuration fields (image, service, probes, etc.)
- [runes.md](runes.md) -- Adding external Helm charts alongside glyphs
- [trinkets.md](trinkets.md) -- How kaster is registered as a trinket in book configuration
