# Summon

## What is Summon?

```yaml
name: my-app
image: myorg/app:v1.0

workload:
  replicas: 3

service:
  enabled: true
  ports:
    - port: 8080
```

Summon is the primary Helm chart in Runik Platform for deploying workloads to Kubernetes. It lives at `charts/summon/` and serves as the universal workload chart -- you describe what you want, and summon generates the correct Kubernetes resources.

When a spell has no `chart:` or `path:`, the Librarian uses summon (the defaultTrinket) as the primary source. Summon then renders the appropriate workload (Deployment, StatefulSet, Job, CronJob, or DaemonSet) along with associated resources like Services, ConfigMaps, Secrets, ServiceAccounts, and PodDisruptionBudgets.

You configure summon by adding keys directly to your spell YAML. Every key documented here is a summon value.

## Infrastructure Inline with the Workload

Summon ships its own internal glyph dispatcher. When a spell has no `chart:` and no `path:` (so summon is the primary source), infrastructure glyphs go at the **top level of the spell** — not under a `glyphs:` wrapper. Summon iterates its subcharts and dispatches on subchart names used as top-level spell keys:

```yaml
name: my-app
image: myorg/app:v1.0

vault:                 # <-- handled by summon's internal dispatcher
  creds:
    type: secret
    keys: [api-key]

istio:                 # <-- handled by summon's internal dispatcher
  route:
    type: virtualService
    enabled: true
```

No separate ArgoCD source is emitted for these; they render inside summon's output alongside the Deployment. Use `glyphs:` only when the primary source is an external chart (`chart:` / `path:`) — see [usage/glyphs.md](glyphs.md) for the full explanation of the two dispatchers, and [usage/glyphs.md](glyphs.md) again for the field-level reference for each glyph type.

## Workload Types

```yaml
workload:
  type: deployment
  replicas: 3
```

Summon supports five Kubernetes workload types. You select the type with `workload.type`. If you omit it, summon defaults to `deployment`.

### Deployment

```yaml
name: api-service
image: myorg/api:v2.1.0

workload:
  type: deployment
  replicas: 3
```

Deployment is the default workload type. It manages stateless pods with rolling update strategy. You control the number of replicas with `workload.replicas` (defaults to 1).

### StatefulSet

```yaml
name: postgres
image: postgres:14

workload:
  type: statefulset
  replicas: 3
  volumeClaimTemplates:
    data:
      destinationPath: /var/lib/postgresql/data
      size: 50Gi
      storageClassName: gp3
```

StatefulSets provide stable network identities and persistent storage. Each pod gets a unique ordinal index and its own PersistentVolumeClaim via `volumeClaimTemplates`.

### CronJob

```yaml
name: nightly-backup
image: myorg/backup:v1.0

workload:
  type: cronjob
  schedule: "0 2 * * *"
  backoffLimit: 3
  activeDeadlineSeconds: 3600
```

CronJobs run on a schedule defined by a cron expression. You set `backoffLimit` to control retries and `activeDeadlineSeconds` to set a maximum runtime.

### Job

```yaml
name: db-migration
image: myorg/migrate:v1.0

workload:
  type: job
  backoffLimit: 2

command:
  - /bin/sh
  - -c
  - "migrate -source file:///migrations -database $DB_URL up"
```

Jobs run a task to completion. They differ from CronJobs in that they run once when applied, not on a schedule.

### DaemonSet

```yaml
name: log-collector
image: myorg/fluentd:v1.16

workload:
  type: daemonset
```

DaemonSets run one pod per node. You do not set `replicas` -- Kubernetes schedules one pod on every eligible node automatically.

### Workload Type Reference

| Field | Description | Default |
|-------|-------------|---------|
| `workload.type` | `deployment`, `statefulset`, `job`, `cronjob`, `daemonset` | `deployment` |
| `workload.replicas` | Number of pod replicas | `1` |
| `workload.schedule` | Cron expression (cronjob only) | -- |
| `workload.backoffLimit` | Retry count (job/cronjob) | -- |
| `workload.activeDeadlineSeconds` | Max runtime in seconds (job/cronjob) | -- |
| `workload.volumeClaimTemplates` | Per-pod PVCs (statefulset only) | -- |

## Container Configuration

```yaml
name: api-service
image: myorg/api:v2.1.0

command:
  - /app/server
args:
  - --port=8080
  - --config=/etc/app/config.yaml

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

workload:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL

securityContext:
  runAsNonRoot: true
  fsGroup: 2000
```

You configure the primary container with top-level keys. The `image` field accepts either a short string (`myorg/api:v2.1.0`) or a structured object. The `command` overrides the container entrypoint, and `args` supplies arguments.

### Image Configuration

```yaml
# Short form
image: myorg/api:v2.1.0

# Structured form
image:
  repository: myorg/api
  tag: v2.1.0
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: registry-credentials
```

Both forms are equivalent. Use the short form when you only need repository and tag. Use the structured form when you need to set `pullPolicy` or when repository and tag come from different merge layers.

### Container Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `image` | Container image (string or object) | -- (required) |
| `image.repository` | Image repository | -- |
| `image.tag` | Image tag | -- |
| `image.pullPolicy` | `Always`, `IfNotPresent`, `Never` | `IfNotPresent` |
| `imagePullSecrets` | List of pull secret references | `[]` |
| `command` | Entrypoint override (list of strings) | -- |
| `args` | Arguments to entrypoint (list of strings) | -- |
| `resources.requests.cpu` | CPU request | -- |
| `resources.requests.memory` | Memory request | -- |
| `resources.limits.cpu` | CPU limit | -- |
| `resources.limits.memory` | Memory limit | -- |
| `workload.securityContext.runAsNonRoot` | Require the primary container to run as non-root | -- |
| `workload.securityContext.runAsUser` | UID for the primary container | -- |
| `workload.securityContext.readOnlyRootFilesystem` | Mount the primary container root filesystem read-only | -- |
| `workload.securityContext.capabilities.drop` | Linux capabilities to drop from the primary container | -- |
| `securityContext.fsGroup` | Pod-level filesystem group | -- |

## Probes

```yaml
probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 10
    periodSeconds: 15
    failureThreshold: 3

  readiness:
    httpGet:
      path: /ready
      port: 8080
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 3

  startup:
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 0
    periodSeconds: 5
    failureThreshold: 30
```

Probes tell Kubernetes how to check your container health. You configure them under the `probes` key with three types: `liveness` (restart if failing), `readiness` (remove from service if failing), and `startup` (delay other probes until passing).

### Probe Methods

Each probe supports three check methods. You use exactly one per probe.

**httpGet** -- sends an HTTP GET request:

```yaml
probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
```

**tcpSocket** -- opens a TCP connection:

```yaml
probes:
  readiness:
    tcpSocket:
      port: 5432
```

**exec** -- runs a command inside the container:

```yaml
probes:
  liveness:
    exec:
      command:
        - pg_isready
        - -U
        - postgres
```

### Probe Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `probes.liveness` | Restarts container on failure | -- |
| `probes.readiness` | Removes pod from Service endpoints on failure | -- |
| `probes.startup` | Gates liveness/readiness until pod is started | -- |
| `.httpGet.path` | HTTP path to check | -- |
| `.httpGet.port` | Port for HTTP check | -- |
| `.tcpSocket.port` | Port for TCP check | -- |
| `.exec.command` | Command to execute (list) | -- |
| `.initialDelaySeconds` | Seconds before first probe | `0` |
| `.periodSeconds` | Seconds between probes | `10` |
| `.failureThreshold` | Consecutive failures before action | `3` |

## Service Exposure

```yaml
service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
    - port: 443
      targetPort: 8443
      protocol: TCP
      name: https
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
  labels:
    exposure: internal
```

You enable a Kubernetes Service by setting `service.enabled: true`. The Service routes traffic to your pods based on label selectors that summon manages automatically.

### Service Types

| Type | Description | Use Case |
|------|-------------|----------|
| `ClusterIP` | Internal cluster IP only | Default; internal services |
| `NodePort` | Exposes on each node's IP at a static port | Direct node access |
| `LoadBalancer` | Provisions a cloud load balancer | External-facing services |

### Service Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `service.enabled` | Create a Service resource | `false` |
| `service.type` | `ClusterIP`, `NodePort`, `LoadBalancer` | `ClusterIP` |
| `service.ports` | List of port mappings | -- |
| `service.ports[].port` | Service port (external) | -- |
| `service.ports[].targetPort` | Container port (internal) | same as `port` |
| `service.ports[].protocol` | `TCP` or `UDP` | `TCP` |
| `service.ports[].name` | Port name (required if multiple ports) | -- |
| `service.annotations` | Service annotations (load balancer config, etc.) | `{}` |
| `service.labels` | Additional labels on the Service | `{}` |

## Environment Variables

```yaml
envs:
  # Simple value
  APP_ENV: production
  LOG_LEVEL: info

  # From a Kubernetes Secret
  DB_PASSWORD:
    type: secret
    name: postgres-credentials
    key: password

  # From a ConfigMap
  FEATURE_FLAGS:
    type: configmap
    name: feature-config
    key: flags
```

You set environment variables on your container using the `envs` map. Each key becomes the environment variable name. The value is either a plain string (injected directly) or an object referencing a Secret or ConfigMap.

### envFrom -- Bulk Loading

```yaml
envFrom:
  - secretRef:
      name: app-secrets
  - configMapRef:
      name: app-config
      prefix: CFG_
```

Use `envFrom` to load all keys from a Secret or ConfigMap as environment variables at once. The optional `prefix` prepends a string to each variable name, which helps avoid collisions when loading multiple sources.

### Environment Variable Reference

| Pattern | Description |
|---------|-------------|
| `envs.KEY: value` | Literal string value |
| `envs.KEY: {type: secret, name: X, key: Y}` | Value from Secret `X`, key `Y` |
| `envs.KEY: {type: configmap, name: X, key: Y}` | Value from ConfigMap `X`, key `Y` |
| `envFrom[].secretRef.name` | Load all keys from Secret as env vars |
| `envFrom[].configMapRef.name` | Load all keys from ConfigMap as env vars |
| `envFrom[].configMapRef.prefix` | Prefix added to each loaded key |

## ConfigMaps and Secrets

```yaml
configMaps:
  app-env:
    contentType: env
    content:
      DATABASE_HOST: postgres.databases.svc
      DATABASE_PORT: "5432"
      CACHE_TTL: "300"

  app-config:
    contentType: yaml
    mountPath: /etc/app
    name: config.yaml
    content:
      server:
        port: 8080
        readTimeout: 30s
      features:
        enableNewUI: true

secrets:
  api-keys:
    contentType: env
    content:
      API_KEY: c2VjcmV0LWtleQ==
      API_SECRET: c2VjcmV0LXZhbHVl

  tls-cert:
    contentType: file
    mountPath: /etc/tls
    name: tls.crt
    content: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
```

Summon provides a unified `contentType` system for both ConfigMaps and Secrets. The `contentType` determines how the data is created and consumed by your container.

### contentType: env

```yaml
configMaps:
  runtime-config:
    contentType: env
    content:
      LOG_FORMAT: json
      WORKERS: "4"
```

Creates a ConfigMap (or Secret) and loads its keys as environment variables. You do not need to specify `envFrom` separately -- summon handles the wiring.

### contentType: file

```yaml
configMaps:
  nginx-conf:
    contentType: file
    mountPath: /etc/nginx/conf.d
    name: default.conf
    content: |
      server {
          listen 80;
          location / {
              proxy_pass http://localhost:8080;
          }
      }
```

Mounts the content as a file at `mountPath/name`. The `content` is a raw string. Use this for configuration files, scripts, or certificates.

### contentType: yaml

```yaml
configMaps:
  app-settings:
    contentType: yaml
    mountPath: /etc/app
    name: settings.yaml
    content:
      database:
        host: postgres.svc
        port: 5432
        pool: 20
      cache:
        enabled: true
        ttl: 300
```

Mounts the content as a YAML file. You write the `content` as a YAML object and summon serializes it to a `.yaml` file at `mountPath/name`. This keeps your spell readable since you avoid embedding YAML-as-string.

### contentType: json

```yaml
configMaps:
  app-manifest:
    contentType: json
    mountPath: /etc/app
    name: manifest.json
    content:
      version: "2.1.0"
      features:
        - auth
        - billing
```

Same as `yaml` but serializes to JSON format.

### ConfigMap/Secret Location

You can either create a new ConfigMap/Secret (default) or reference an existing one:

```yaml
configMaps:
  # Create new (default behavior)
  new-config:
    contentType: env
    content:
      KEY: value

  # Reference existing
  existing-config:
    contentType: env
    location: local
```

When `location: local` is set, summon does not create the resource -- it references one that already exists in the cluster.

### Content Type Reference

| `contentType` | Creates | Consumed As | Requires |
|---------------|---------|-------------|----------|
| `env` | ConfigMap/Secret | Environment variables | `content` (key-value map) |
| `file` | ConfigMap/Secret | Mounted file | `content` (string), `mountPath`, `name` |
| `yaml` | ConfigMap/Secret | Mounted YAML file | `content` (YAML object), `mountPath`, `name` |
| `json` | ConfigMap/Secret | Mounted JSON file | `content` (object), `mountPath`, `name` |

## Volumes

```yaml
volumes:
  data:
    type: pvc
    destinationPath: /data
    name: data-volume
    size: 20Gi

  cache:
    type: emptyDir
    destinationPath: /tmp/cache
    size: 1Gi
```

You attach storage to your pods with the `volumes` map. Each named entry specifies a `type` and a `destinationPath` where the volume mounts inside the container.

### PVC (Persistent Volume Claim)

```yaml
volumes:
  data:
    type: pvc
    destinationPath: /data
    name: my-data
    size: 20Gi
    storageClass: gp3
    accessMode: ReadWriteOnce
```

Summon creates a PVC for every `type: pvc` entry. `name` optionally overrides the generated claim/resource name; `size`, `storageClass`, and `accessMode` configure it.

### hostPath

```yaml
volumes:
  host-logs:
    type: hostPath
    destinationPath: /var/log/host
    path: /var/log
```

Mounts a directory from the host node. Use sparingly -- hostPath volumes tie your pod to a specific node's filesystem.

### NFS

```yaml
volumes:
  shared:
    type: nfs
    destinationPath: /shared
    server: nfs.internal.example.com
    path: /exports/shared-data
```

Mounts an NFS share. You provide the NFS `server` address and the export `path`.

### emptyDir

```yaml
volumes:
  scratch:
    type: emptyDir
    destinationPath: /tmp/scratch
    size: 512Mi
    inMemory: true
```

Creates an ephemeral volume that exists for the pod's lifetime. Set `inMemory: true` to use a tmpfs (RAM-backed) volume. Use `size` to cap its size.

### VolumeClaimTemplates (StatefulSet)

```yaml
workload:
  type: statefulset
  replicas: 3
  volumeClaimTemplates:
    data:
      destinationPath: /var/lib/data
      size: 100Gi
      storageClassName: gp3
    wal:
      destinationPath: /var/lib/wal
      size: 20Gi
      storageClassName: gp3-iops
```

VolumeClaimTemplates are exclusive to StatefulSets. Each replica gets its own PVC (e.g., `data-postgres-0`, `data-postgres-1`). You define them under `workload.volumeClaimTemplates` with a name key, a `destinationPath`, `size`, and optionally `storageClassName`.

`destinationPath` is mandatory for every volume or claim template that produces
a container mount. Runik currently treats this as an input contract and does not
enforce it with Helm `required` validation.

### Volume Type Reference

| Type | Fields | Description |
|------|--------|-------------|
| `pvc` | `destinationPath`, `name`, `size`, `storageClass`, `accessMode` | Persistent volume claim |
| `hostPath` | `destinationPath`, `path` | Host node directory |
| `nfs` | `destinationPath`, `server`, `path` | NFS mount |
| `emptyDir` | `destinationPath`, `size`, `inMemory` | Ephemeral pod-local volume |
| VCT | `destinationPath`, `size`, `storageClassName` | Per-replica PVC (StatefulSet) |

## Autoscaling

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```

Enabling autoscaling creates a HorizontalPodAutoscaler (HPA) that adjusts your replica count based on resource utilization.

When you enable autoscaling, `workload.replicas` is ignored. The HPA manages replica count between `minReplicas` and `maxReplicas`.

### Autoscaling Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `autoscaling.enabled` | Create an HPA | `false` |
| `autoscaling.minReplicas` | Minimum replica count | -- |
| `autoscaling.maxReplicas` | Maximum replica count | -- |
| `autoscaling.targetCPUUtilizationPercentage` | CPU target (percent of request) | -- |
| `autoscaling.targetMemoryUtilizationPercentage` | Memory target (percent of request) | -- |

## Pod Scheduling

```yaml
nodeSelector:
  kubernetes.io/arch: amd64
  node-type: compute

tolerations:
  - key: dedicated
    operator: Equal
    value: gpu
    effect: NoSchedule

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - api-service
          topologyKey: kubernetes.io/hostname
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values:
                - us-east-1a
                - us-east-1b
```

You control where your pods run with three scheduling mechanisms. `nodeSelector` is the simplest -- it constrains pods to nodes with matching labels. `tolerations` allow your pods to run on tainted nodes. `affinity` provides advanced rules for pod placement relative to other pods or node properties.

### Scheduling Fields Reference

| Field | Description |
|-------|-------------|
| `nodeSelector` | Key-value map; pod runs only on nodes with all matching labels |
| `tolerations[].key` | Taint key to tolerate |
| `tolerations[].operator` | `Equal` or `Exists` |
| `tolerations[].value` | Taint value (when operator is `Equal`) |
| `tolerations[].effect` | `NoSchedule`, `PreferNoSchedule`, or `NoExecute` |
| `affinity.podAntiAffinity` | Spread pods away from each other |
| `affinity.podAffinity` | Co-locate pods together |
| `affinity.nodeAffinity` | Constrain to nodes by label expressions |

## Init Containers and Sidecars

### Init Containers

```yaml
initContainers:
  wait-for-db:
    image: busybox:1.36
    command:
      - sh
      - -c
      - "until nc -z postgres.databases.svc 5432; do sleep 2; done"

  run-migrations:
    image: myorg/migrate:v1.0
    command:
      - migrate
      - -source
      - file:///migrations
      - -database
      - $(DATABASE_URL)
      - up
    envs:
      DATABASE_URL:
        type: secret
        name: db-credentials
        key: url
```

Init containers run sequentially before your main container starts. They are defined under `initContainers` as a named map. Each init container supports `image`, `command`, `args`, `envs`, and `envFrom`. Use init containers for setup tasks like waiting for dependencies, running migrations, or populating shared volumes.

### Sidecars

```yaml
sideCars:
  cloud-sql-proxy:
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.8.0
    command:
      - /cloud-sql-proxy
      - --port=5432
      - myproject:us-central1:mydb
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi

  log-shipper:
    image: myorg/log-agent:v1.0
    args:
      - --source=/var/log/app
      - --destination=https://logs.example.com
```

Sidecars run alongside your main container for the lifetime of the pod. They are defined under `sideCars` as a named map. Each sidecar supports `image`, `command`, `args`, and `resources`. Use sidecars for cross-cutting concerns like database proxies, log shippers, or service meshes.

### Init Container / Sidecar Fields Reference

| Field | Description |
|-------|-------------|
| `initContainers.NAME.image` | Container image |
| `initContainers.NAME.command` | Entrypoint override |
| `initContainers.NAME.args` | Arguments |
| `initContainers.NAME.envs` | Environment variables (same syntax as top-level `envs`) |
| `initContainers.NAME.envFrom` | Bulk env loading (same syntax as top-level `envFrom`) |
| `sideCars.NAME.image` | Container image |
| `sideCars.NAME.command` | Entrypoint override |
| `sideCars.NAME.args` | Arguments |
| `sideCars.NAME.resources` | CPU/memory requests and limits |

## ServiceAccount

```yaml
serviceAccount:
  enabled: true
  automount: true
  name: api-service-sa
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/api-role
    vault.hashicorp.com/role: api-reader
  labels:
    managed-by: runik
```

Setting `serviceAccount.enabled: true` creates a ServiceAccount and binds it to your pods. The `automount` field controls whether the service account token is automatically mounted into the pod. Use `annotations` to integrate with cloud IAM (e.g., AWS IRSA) or Vault authentication.

### ServiceAccount Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `serviceAccount.enabled` | Create a ServiceAccount | `false` |
| `serviceAccount.automount` | Mount token into pods | `true` |
| `serviceAccount.name` | ServiceAccount name | release name |
| `serviceAccount.annotations` | Annotations (IAM, Vault, etc.) | `{}` |
| `serviceAccount.labels` | Additional labels | `{}` |

## PodDisruptionBudget

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 2
```

A PodDisruptionBudget (PDB) limits how many pods can be taken down during voluntary disruptions like node drains or cluster upgrades. You set either `minAvailable` (minimum pods that must remain running) or `maxUnavailable` (maximum pods that can be unavailable), but not both.

### PDB Fields Reference

| Field | Description | Default |
|-------|-------------|---------|
| `podDisruptionBudget.enabled` | Create a PDB | `false` |
| `podDisruptionBudget.minAvailable` | Min pods that must stay running | -- |
| `podDisruptionBudget.maxUnavailable` | Max pods that can be down | -- |

## Labels

```yaml
labels:
  finops:
    enabled: true
    team: platform
    owner: jane.doe
    costCenter: CC-1234
    department: engineering
    project: runik
    environment: production

  covenant:
    enabled: true
    team: platform
    owner: jane.doe
    department: engineering
    organization: acme-corp
```

Summon supports two structured label systems. `finops` labels enable cost tracking and chargeback across your organization. `covenant` labels publish metadata for the Covenant IAM renderer. Both label sets are applied to all resources generated by the spell.

### Label Fields Reference

| Label Set | Fields |
|-----------|--------|
| `labels.finops` | `enabled`, `team`, `owner`, `costCenter`, `department`, `project`, `environment` |
| `labels.covenant` | `enabled`, `team`, `owner`, `department`, `organization` |

## Complete Examples

### Example 1: API Service

A production REST API with autoscaling, health checks, environment configuration, and disruption budget.

```yaml
name: payment-api
namespace: applications
image: myorg/payment-api:v3.2.1

workload:
  type: deployment
  replicas: 3

resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      name: http

probes:
  liveness:
    httpGet:
      path: /healthz
      port: 8080
    initialDelaySeconds: 10
    periodSeconds: 15
    failureThreshold: 3
  readiness:
    httpGet:
      path: /ready
      port: 8080
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 3
  startup:
    httpGet:
      path: /healthz
      port: 8080
    periodSeconds: 5
    failureThreshold: 30

envs:
  APP_ENV: production
  LOG_LEVEL: info
  DB_HOST: postgres.databases.svc
  DB_PASSWORD:
    type: secret
    name: payment-db-credentials
    key: password

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 15
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60

podDisruptionBudget:
  enabled: true
  minAvailable: 2

serviceAccount:
  enabled: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payment-api

labels:
  finops:
    enabled: true
    team: payments
    owner: alice.smith
    costCenter: CC-5678
    department: engineering
    project: payment-platform
    environment: production
```

This spell generates: Deployment (3 replicas), Service (ClusterIP:80 -> 8080), HPA (3-15 replicas), PDB (minAvailable: 2), ServiceAccount with AWS IRSA.

### Example 2: StatefulSet Database

A PostgreSQL cluster with persistent storage, exec probes, and secrets.

```yaml
name: postgres
namespace: databases
image: postgres:14

workload:
  type: statefulset
  replicas: 3
  volumeClaimTemplates:
    data:
      destinationPath: /var/lib/postgresql/data
      size: 100Gi
      storageClassName: gp3
    wal:
      destinationPath: /var/lib/postgresql/wal
      size: 20Gi
      storageClassName: gp3-iops

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: "2"
    memory: 4Gi

service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 5432
      name: postgres

probes:
  liveness:
    exec:
      command:
        - pg_isready
        - -U
        - postgres
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 3
  readiness:
    exec:
      command:
        - pg_isready
        - -U
        - postgres
    initialDelaySeconds: 5
    periodSeconds: 5
    failureThreshold: 3

envs:
  POSTGRES_DB: appdb
  PGDATA: /var/lib/postgresql/data/pgdata
  POSTGRES_USER:
    type: secret
    name: postgres-credentials
    key: username
  POSTGRES_PASSWORD:
    type: secret
    name: postgres-credentials
    key: password

envFrom:
  - secretRef:
      name: postgres-credentials

nodeSelector:
  node-type: database

tolerations:
  - key: dedicated
    operator: Equal
    value: database
    effect: NoSchedule

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1
```

This spell generates: StatefulSet (3 replicas), 2 PVCs per replica (data: 100Gi, wal: 20Gi), Service (ClusterIP:5432), PDB (maxUnavailable: 1).

### Example 3: CronJob Backup

A nightly backup job that reads configuration from a YAML ConfigMap and writes to a persistent volume.

```yaml
name: nightly-db-backup
namespace: batch
image: myorg/db-backup:v2.0

workload:
  type: cronjob
  schedule: "0 2 * * *"
  backoffLimit: 3
  activeDeadlineSeconds: 7200

command:
  - /backup
  - --config=/etc/backup/config.yaml
  - --destination=/backups

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi

configMaps:
  backup-config:
    contentType: yaml
    mountPath: /etc/backup
    name: config.yaml
    content:
      database:
        host: postgres.databases.svc
        port: 5432
        name: appdb
      backup:
        format: custom
        compression: 9
        parallel: 4
      retention:
        daily: 7
        weekly: 4
        monthly: 12

volumes:
  backups:
    type: pvc
    destinationPath: /backups
    name: backup-storage
    size: 100Gi

envs:
  DB_PASSWORD:
    type: secret
    name: postgres-credentials
    key: password

serviceAccount:
  enabled: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/backup-writer

labels:
  finops:
    enabled: true
    team: platform
    owner: bob.jones
    costCenter: CC-0001
    department: infrastructure
    project: disaster-recovery
    environment: production
```

This spell generates: CronJob (runs at 02:00 daily), ConfigMap (YAML config mounted at /etc/backup/config.yaml), ServiceAccount with S3 write access.

### Example 4: Application with Init Container

A web application that runs database migrations before starting, with a sidecar for log shipping.

```yaml
name: web-app
namespace: applications
image: myorg/web-app:v4.1.0

workload:
  type: deployment
  replicas: 2

initContainers:
  wait-for-db:
    image: busybox:1.36
    command:
      - sh
      - -c
      - "until nc -z postgres.databases.svc 5432; do echo 'waiting for db...'; sleep 2; done"

  run-migrations:
    image: myorg/web-app:v4.1.0
    command:
      - /app/migrate
      - --source=file:///migrations
      - up
    envs:
      DATABASE_URL:
        type: secret
        name: web-app-db
        key: url

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi

service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 3000
      name: http

probes:
  liveness:
    httpGet:
      path: /health
      port: 3000
    initialDelaySeconds: 10
    periodSeconds: 15
  readiness:
    httpGet:
      path: /ready
      port: 3000
    initialDelaySeconds: 5
    periodSeconds: 10

envs:
  NODE_ENV: production
  PORT: "3000"
  DATABASE_URL:
    type: secret
    name: web-app-db
    key: url
  SESSION_SECRET:
    type: secret
    name: web-app-secrets
    key: session-secret

configMaps:
  app-settings:
    contentType: yaml
    mountPath: /etc/app
    name: settings.yaml
    content:
      cache:
        enabled: true
        ttl: 600
      rateLimit:
        windowMs: 60000
        maxRequests: 100

sideCars:
  log-shipper:
    image: myorg/log-agent:v1.2
    args:
      - --source=/var/log/app
      - --destination=https://logs.example.com
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

This spell generates: Deployment (2 replicas) with 2 init containers (wait-for-db, run-migrations), 1 sidecar (log-shipper), Service (ClusterIP:80 -> 3000), ConfigMap (YAML), PDB (minAvailable: 1). The init containers run in order -- the database connectivity check completes before migrations start, and both finish before the main container launches.

## Cross-References

- [spells.md](spells.md) -- How to write spells and the 7 spell types
- [bookrack.md](bookrack.md) -- Configuration hierarchy, books, chapters, and merging
- [glyphs.md](glyphs.md) -- Adding Vault secrets, Istio routing, cert-manager certificates
- [runes.md](runes.md) -- Including external Helm charts alongside your workload
- [trinkets.md](trinkets.md) -- Microspell for opinionated microservices, Tarot for reusable processes
- [lexicon.md](lexicon.md) -- Registering and discovering infrastructure dynamically
- [deploying.md](deploying.md) -- Running the Librarian and deploying to clusters
- [debugging.md](debugging.md) -- Troubleshooting common summon issues
