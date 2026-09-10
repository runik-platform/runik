# Deploying with Librarian and ArgoCD

## Running the Librarian

### Render a Book Locally

```bash
helm template librarian/ --set name=production
```

This reads every spell in `bookrack/production/`, walks its chapters in order, and outputs one ArgoCD `Application` manifest per spell plus an `AppProject` manifest for the book.

### Output to a File

```bash
helm template librarian/ --set name=production > production-apps.yaml
```

You can inspect the generated manifests before applying them:

```bash
cat production-apps.yaml
```

### Apply Directly to the Cluster

```bash
helm template librarian/ --set name=production | kubectl apply -f -
```

This creates every ArgoCD Application in a single command. ArgoCD then takes over and syncs each Application to deploy the actual Kubernetes resources.

## Bootstrap Application in ArgoCD

Instead of running `helm template` manually, you create a single ArgoCD Application that points to the librarian chart. ArgoCD renders the chart itself and manages all child Applications automatically.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: production-librarian
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-runik-repo.git
    path: librarian
    targetRevision: main
    helm:
      parameters:
        - name: name
          value: production
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply this once:

```bash
kubectl apply -f production-librarian.yaml
```

From this point forward, everything is GitOps-driven. You never run `helm template` again -- ArgoCD does it for you on every sync.

The aggregate Runik example uses this exact layout in `bookdeclaration.yaml`:
`repoURL: https://github.com/runik-platform/runik.git`, `path: librarian`, and
`targetRevision: upstream`. The `librarian/bookrack -> ../bookrack` symlink is
tracked by the Librarian submodule, so rendering by release name finds
`bookrack/<release>/index.yaml` without a second values-file reference. Argo CD
must clone the aggregate repository recursively and have access to its declared
submodule remotes.

## Apps-of-Apps Pattern

The librarian implements the ArgoCD apps-of-apps pattern. From your perspective, the hierarchy looks like this:

```
Bootstrap Application (production-librarian)
  |
  |-- renders librarian chart with name=production
  |
  +-- Child Application: istio-external-gateway
  +-- Child Application: cert-manager
  +-- Child Application: api-service
  +-- Child Application: payment-service
  +-- Child Application: ...one per spell
```

You write spells in the bookrack. The librarian reads them and generates one ArgoCD Application per spell. ArgoCD sees these child Applications and syncs each one independently, deploying the actual Kubernetes resources through the appropriate charts (summon, kaster, external charts, etc.).

### What You Control vs. What the Librarian Generates

| You Write | Librarian Generates |
|-----------|---------------------|
| `bookrack/production/index.yaml` | `AppProject` for the book |
| `bookrack/production/apps/api.yaml` | `Application` with summon source |
| `bookrack/production/apps/nginx.yaml` (external chart) | `Application` with external chart source |
| `bookrack/production/infra/gateway.yaml` (glyphs only) | `Application` with kaster source |

You never write ArgoCD Application manifests by hand. The librarian produces them from your spells.

## Complete Deploy Workflow

The end-to-end flow from writing a spell to a running application:

```
1. Write spell           bookrack/production/apps/api-service.yaml
       |
2. Git push              git add . && git commit && git push
       |
3. ArgoCD syncs          ArgoCD detects change in repo, syncs the
   librarian             bootstrap Application (production-librarian)
       |
4. Librarian generates   helm template renders a new Application
   Application           manifest for api-service
       |
5. ArgoCD syncs          ArgoCD detects the new child Application
   Application           and begins syncing it
       |
6. Charts rendered       summon/kaster/external chart templates
                         produce Deployment, Service, VaultSecret, etc.
       |
7. K8s resources         kubectl apply runs behind the scenes --
   created               pods, services, secrets appear in the cluster
       |
8. App running           your application is live
```

### Walkthrough

1. You create a spell file:

```yaml
# bookrack/production/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0
service:
  enabled: true
```

2. You push to Git:

```bash
git add bookrack/production/apps/api-service.yaml
git commit -m "add api-service spell"
git push
```

3. ArgoCD notices the change in the repository and re-renders the librarian chart. The librarian sees the new spell and outputs an additional `Application` manifest.

4. ArgoCD detects the new child Application and syncs it, pulling the summon chart, passing your spell values, and applying the resulting Deployment and Service to the cluster.

No manual intervention is needed after the initial bootstrap.

## appParams Configuration

The `appParams` block controls how the librarian generates each ArgoCD Application. You can set `appParams` at the book level (in `index.yaml`), at the chapter level (in `chapter/index.yaml`), or at the spell level. Spell-level values override chapter-level values, which override book-level values.

### disableAutoSync

```yaml
appParams:
  disableAutoSync: true
```

When set to `true`, the generated Application has no `automated` sync policy. You must sync it manually through the ArgoCD UI or CLI. Use this for critical infrastructure you want to review before applying.

```yaml
# bookrack/production/infra/argocd.yaml
name: argocd
repository: https://github.com/argoproj/argo-helm.git
path: charts/argo-cd
revision: argo-cd-9.1.1
namespace: argocd

appParams:
  disableAutoSync: true   # Manual sync for ArgoCD itself
```

### customFinalizers

```yaml
appParams:
  customFinalizers:
    - resources-finalizer.argocd.argoproj.io
```

Sets the `metadata.finalizers` field on the generated Application. The `resources-finalizer` tells ArgoCD to delete all managed Kubernetes resources when the Application is deleted. Without it, deleting the Application leaves orphaned resources in the cluster.

```yaml
name: temporary-test
image: myorg/test:latest

appParams:
  customFinalizers:
    - resources-finalizer.argocd.argoproj.io
```

### annotations

```yaml
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "10"
    notifications.argoproj.io/subscribe.on-sync-succeeded.slack: deployments
```

Sets `metadata.annotations` on the generated Application. Common uses:

| Annotation | Purpose |
|-----------|---------|
| `argocd.argoproj.io/sync-wave: "10"` | Controls deployment order within a sync -- lower waves sync first |
| `notifications.argoproj.io/subscribe.on-sync-succeeded.slack: channel` | Sends a Slack notification when the Application syncs successfully |
| `notifications.argoproj.io/subscribe.on-health-degraded.slack: channel` | Sends a Slack notification when health degrades |

```yaml
# Deploy infrastructure before applications using sync waves
# bookrack/production/infra/istio.yaml
name: istio-gateway
namespace: istio-system

appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "-5"

glyphs:
  istio:
    external-gateway:
      type: gateway
      selector:
        istio: gateway
```

```yaml
# bookrack/production/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "10"
    notifications.argoproj.io/subscribe.on-sync-succeeded.slack: deployments
```

### syncPolicy

The `syncPolicy` block maps directly to the ArgoCD Application `spec.syncPolicy`. The librarian defaults are defined in `librarian/values.yaml`:

```yaml
appParams:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 2
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

#### syncPolicy Reference

| Field | Default | Description |
|-------|---------|-------------|
| `automated.prune` | `true` | Deletes resources that are no longer in Git |
| `automated.selfHeal` | `true` | Reverts manual changes made directly in the cluster |
| `syncOptions: CreateNamespace=true` | Enabled | Creates the target namespace if it does not exist |
| `syncOptions: PrunePropagationPolicy=foreground` | Enabled | Waits for dependents to be deleted before the owner |
| `syncOptions: PruneLast=true` | Enabled | Prunes resources only after all other sync operations complete |
| `retry.limit` | `2` | Number of times to retry a failed sync |
| `retry.backoff.duration` | `5s` | Initial backoff delay |
| `retry.backoff.factor` | `2` | Multiplier applied to the delay after each retry |
| `retry.backoff.maxDuration` | `3m` | Maximum backoff delay |

You can override any of these at the spell level:

```yaml
name: critical-database
repository: https://charts.bitnami.com/bitnami
chart: postgresql
revision: 12.8.0
namespace: databases

appParams:
  syncPolicy:
    automated:
      prune: false       # Never auto-delete database resources
      selfHeal: true
    retry:
      limit: 5           # More retries for flaky CRD installs
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 10m
```

### managedNamespaceMetadata

```yaml
appParams:
  managedNamespaceMetadata:
    labels:
      istio-injection: enabled
      environment: production
    annotations:
      scheduler.alpha.kubernetes.io/defaultTolerations: '[{"key":"dedicated","operator":"Equal","value":"apps","effect":"NoSchedule"}]'
```

When `CreateNamespace=true` is active in `syncOptions`, ArgoCD creates the target namespace. The `managedNamespaceMetadata` block lets you set labels and annotations on that namespace. This is how you enable Istio sidecar injection or apply other namespace-level policies without managing Namespace manifests separately.

```yaml
name: api-service
namespace: applications
image: myorg/api:v1.0

appParams:
  managedNamespaceMetadata:
    labels:
      istio-injection: enabled
      team: backend
```

ArgoCD creates the `applications` namespace with `istio-injection: enabled`, so every pod in that namespace automatically gets an Istio sidecar.

### ignoreDifferences

```yaml
appParams:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

Tells ArgoCD to ignore specific fields when comparing the desired state (Git) with the live state (cluster). This prevents ArgoCD from showing the Application as out-of-sync when an external controller (such as HPA) modifies a field.

#### Common ignoreDifferences Patterns

| Scenario | Configuration |
|----------|---------------|
| HPA manages replicas | `group: apps`, `kind: Deployment`, `jsonPointers: [/spec/replicas]` |
| Mutating webhook adds fields | `group: ""`, `kind: Service`, `jsonPointers: [/metadata/annotations]` |
| Controller updates status | `group: apps`, `kind: Deployment`, `jsonPointers: [/status]` |

```yaml
name: autoscaled-api
image: myorg/api:v1.0

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 20

appParams:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
    - group: autoscaling
      kind: HorizontalPodAutoscaler
      jsonPointers:
        - /spec/metrics
```

Runes can also contribute `ignoreDifferences` entries. The librarian merges them with the spell-level entries automatically:

```yaml
runes:
  - repository: https://charts.bitnami.com/bitnami
    chart: redis
    revision: 17.11.3
    appParams:
      ignoreDifferences:
        - group: apps
          kind: StatefulSet
          jsonPointers:
            - /spec/volumeClaimTemplates
```

## clusterSelector (Multi-Cluster Targeting)

By default, the librarian targets the local cluster (`https://kubernetes.default.svc`). To deploy to a remote cluster, you use `clusterSelector` together with a lexicon entry of type `k8s-cluster`.

### Register Clusters in the Lexicon

First, register your clusters as lexicon entries. You can do this in the book `index.yaml`, in a chapter `index.yaml`, or in a spell's `appendix`:

```yaml
# bookrack/production/index.yaml
appendix:
  lexicon:
    us-west-cluster:
      type: k8s-cluster
      clusterURL: https://k8s-us-west.example.com
      labels:
        region: us-west
        environment: production

    eu-central-cluster:
      type: k8s-cluster
      clusterURL: https://k8s-eu-central.example.com
      labels:
        region: eu-central
        environment: production
```

### Select a Cluster

Use `clusterSelector` with labels that match the lexicon entry. The librarian uses the runic indexer to find a `k8s-cluster` entry whose labels match your selector and sets the Application's `destination.server` to its `clusterURL`.

```yaml
# bookrack/production/apps/api-service.yaml
name: api-service
image: myorg/api:v1.0

clusterSelector:
  region: us-west
  environment: production
```

The generated Application will have:

```yaml
destination:
  server: https://k8s-us-west.example.com
  namespace: api-service
```

### Selector Scope

You can set `clusterSelector` at three levels:

| Level | Scope |
|-------|-------|
| Book (`index.yaml`) | All spells in the book target this cluster |
| Chapter (`chapter/index.yaml`) | All spells in the chapter target this cluster |
| Spell (spell file) | Only this spell targets this cluster |

Spell-level overrides chapter-level, which overrides book-level. This lets you set a default cluster for the book and override it for specific spells.

```yaml
# Book-level default: all spells go to us-west
# bookrack/production/index.yaml
clusterSelector:
  region: us-west

# One spell overrides to eu-central
# bookrack/production/apps/eu-api.yaml
name: eu-api
image: myorg/api:v1.0
clusterSelector:
  region: eu-central
```

### Multi-Cluster Example

Deploy the same application to multiple clusters by placing it in separate books or by using different spells:

```
bookrack/
  us-west/
    index.yaml          # clusterSelector: { region: us-west }
    apps/
      api-service.yaml  # deployed to us-west cluster
  eu-central/
    index.yaml          # clusterSelector: { region: eu-central }
    apps/
      api-service.yaml  # deployed to eu-central cluster
```

Each book targets a different cluster. The bootstrap Application runs the librarian once per book:

```bash
helm template librarian/ --set name=us-west
helm template librarian/ --set name=eu-central
```

Or create two bootstrap Applications in ArgoCD, one per book.

## Complete appParams Example

This spell demonstrates every `appParams` field together:

```yaml
name: payment-gateway
namespace: payments
image: myorg/payment-gw:v3.0

service:
  enabled: true

appParams:
  disableAutoSync: false
  customFinalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "20"
    notifications.argoproj.io/subscribe.on-sync-failed.slack: payments-alerts
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
    retry:
      limit: 3
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  managedNamespaceMetadata:
    labels:
      istio-injection: enabled
      team: payments
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas

clusterSelector:
  region: us-west
  environment: production
```

## Cross-References

- [spells.md](spells.md) -- Spell types, fields, and detection logic
- [bookrack.md](bookrack.md) -- Book and chapter organization, configuration merging
- [summon.md](summon.md) -- All workload configuration fields (Deployment, StatefulSet, Job, etc.)
- [glyphs.md](glyphs.md) -- Infrastructure glyph types (vault, istio, cert-manager, etc.)
- [lexicon.md](lexicon.md) -- Registering infrastructure and dynamic discovery, including k8s-cluster entries
- [runes.md](runes.md) -- Adding external Helm charts as additional sources
- [debugging.md](debugging.md) -- Troubleshooting sync failures and template rendering issues
- [platform-patterns.md](platform-patterns.md) -- Multi-environment, multi-tenant, and multi-cluster patterns
