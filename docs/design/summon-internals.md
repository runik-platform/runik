# Summon Internals

This document describes the internal architecture of the summon chart -- the
template structure, workload type dispatching, the unified contentType system,
service auto-detection, and the TDD testing workflow. You should read
[usage/summon.md](../usage/summon.md) first for the user-facing API; this
document explains how that API is implemented.

## Template Structure

Summon lives at `charts/summon/` and consists of four files plus an examples
directory:

```
charts/summon/
  Chart.yaml              # Chart metadata (name, version, description)
  values.yaml             # Default values and full schema documentation
  templates/
    summon.yaml           # Single orchestrator template
  examples/               # 37 TDD example files (and growing)
    basic-deployment.yaml
    basic-cronjob.yaml
    basic-job.yaml
    statefulset-with-storage.yaml
    configmap-unified-contenttype.yaml
    configmap-json-mount.yaml
    configmap-yaml-mount.yaml
    deployment-with-secrets-env.yaml
    test-port-smart-defaults.yaml
    test-port-container-first.yaml
    test-tdd-failure.yaml
    test-feature-must-exist.yaml
    complex-production.yaml
    ...
```

### Chart.yaml

The chart metadata declares summon as a Helm v2 API chart. It does not list
explicit dependencies -- instead, summon consumes named templates defined in
`charts/glyphs/summon/templates/`, which are made available through the
`charts/summon/charts/` git submodule that tracks the canonical `glyphs.git`
repository.

```yaml
apiVersion: v2
name: summon
version: 1.2.5
description: Kubernetes workload deployment chart for Deployments, StatefulSets, Jobs, CronJobs, and DaemonSets
```

### values.yaml

The values file serves double duty: it provides safe defaults and acts as the
canonical schema reference. Every configurable field is documented inline with
comments and examples. Key top-level sections include:

- `workload` -- type, replicas, schedule, volumeClaimTemplates
- `image` -- repository, tag, pullPolicy
- `service` -- enabled, type, ports
- `configMaps` / `secrets` -- unified contentType system
- `volumes` -- pvc, hostPath, nfs, emptyDir
- `envs` -- simple values, secret refs, configmap refs
- `autoscaling` -- HPA configuration
- `serviceAccount`, `securityContext`, `probes`, `initContainers`, `sideCars`

### templates/summon.yaml -- The Orchestrator

This is the only template file in `charts/summon/templates/`. It does not
define any named templates itself. Instead, it acts as an orchestrator that
dispatches to named templates defined in the glyph library at
`charts/glyphs/summon/templates/`. The full file is short -- roughly 80 lines
-- and follows a strict rendering order:

```go
{{/* 1. Glyph system: iterate subcharts and render glyph types */}}
{{- range $chartName, $_ := $root.Subcharts }}
  {{- range $glyphName, $glyph := get $root.Values $chartName }}
    {{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
  {{- end }}
{{- end }}

{{/* 2. Workload: dispatch to the correct workload template */}}
{{- if .Values.workload.enabled }}
{{- include (printf "summon.workload.%s" .Values.workload.type) . }}
{{- end }}

{{/* 3. ConfigMaps with location: create */}}
{{- range $name, $content := .Values.configMaps }}
  {{- if eq $content.location "create" }}
    {{- include "summon.configMap" (list $root $glyph) }}
  {{- end }}
{{- end }}

{{/* 4. Secrets with location: create */}}
{{- range $name, $content := .Values.secrets }}
  {{- if eq $content.location "create" }}
    {{- include "summon.secrets" (list $root $glyph) }}
  {{- end }}
{{- end }}

{{/* 5. ServiceAccount */}}
{{- if .Values.serviceAccount.enabled }}
{{- include "summon.serviceAccount" . }}
{{- end }}

{{/* 6. Autoscaling (HPA) */}}
{{- if .Values.autoscaling.enabled }}
{{- include "summon.autoscaling" . }}
{{- end }}

{{/* 7. Service (only for deployment, statefulset, daemonset) */}}
{{- if or .Values.service.enabled .Values.services }}
  {{- if or (eq .Values.workload.type "deployment") ... }}
    {{- include "summon.services.render" . }}
  {{- end }}
{{- end }}

{{/* 8. PersistentVolumes and PersistentVolumeClaims */}}
{{- range $name, $volume := .Values.volumes }}
  {{- if eq $volume.type "pvc" }}
    {{- include "summon.pv" ... }}
    {{- include "summon.persistentVolumeClaim" ... }}
  {{- end }}
{{- end }}
```

This single-file orchestrator design means you can read the entire rendering
order in one place without jumping between files.

### Glyph Template Library

The actual template definitions live in `charts/glyphs/summon/templates/`,
organized by concern:

```
charts/glyphs/summon/templates/
  _context.tpl                  # getName helper
  _ports.tpl                    # Port name defaults, container port generation
  service-account.tpl           # ServiceAccount resource
  service.tpl                   # Service resource + multi-service render logic
  storage/
    config-maps.tpl             # ConfigMap resource creation
    secrets.tpl                 # Secret resource creation
    envs.tpl                    # envFrom, env generation
    volumes.tpl                 # Volume definitions (pvc, hostPath, nfs, etc.)
    volume-mounts.tpl           # Volume mount entries per container
    pv.tpl                      # PersistentVolume resource
    pvc.tpl                     # PersistentVolumeClaim resource
    _checksums.tpl              # Config checksum annotations for rollout triggers
  workload/
    _container.tpl              # Container spec (image, command, args, etc.)
    _pod-spec.tpl               # Shared pod spec body (security, scheduling, etc.)
    probes.tpl                  # Liveness, readiness, startup probes
    deployment/
      deployment.tpl            # Deployment resource
      autoscaling.tpl           # HPA resource
    statefulset/
      stateful-set.tpl          # StatefulSet resource + volumeClaimTemplates
    job/
      job.tpl                   # Job resource
    cronjob/
      cronjob.tpl               # CronJob resource
    daemonset/
      daemonset.tpl             # DaemonSet resource
```

## How Workload Type Switching Works

Summon supports five Kubernetes workload types: Deployment, StatefulSet, Job,
CronJob, and DaemonSet. The switching mechanism is a single line of Go
template code in `templates/summon.yaml`:

```go
{{- include (printf "summon.workload.%s" .Values.workload.type) . }}
```

This dynamically constructs a template name from the `workload.type` value and
calls it. When you set `workload.type: cronjob`, it resolves to:

```go
{{- include "summon.workload.cronjob" . }}
```

Each workload type is defined as a named template in its own `.tpl` file under
`charts/glyphs/summon/templates/workload/<type>/`. Here is how each maps:

| `workload.type` | Template Name | K8s Resource | API Group |
|-----------------|---------------|--------------|-----------|
| `deployment` | `summon.workload.deployment` | `Deployment` | `apps/v1` |
| `statefulset` | `summon.workload.statefulset` | `StatefulSet` | `apps/v1` |
| `job` | `summon.workload.job` | `Job` | `batch/v1` |
| `cronjob` | `summon.workload.cronjob` | `CronJob` | `batch/v1` |
| `daemonset` | `summon.workload.daemonset` | `DaemonSet` | `apps/v1` |

### Shared Pod Spec

All five workload templates share the pod specification through two common
templates defined in `_pod-spec.tpl`:

- `summon.common.podSpec` -- wraps the full pod spec including
  `serviceAccountName`, `imagePullSecrets`, `securityContext`, `runtimeClassName`,
  and then calls `summon.common.podSpec.body`.
- `summon.common.podSpec.body` -- renders containers, init containers, sidecars,
  volumes, and volume mounts.

Long-running workloads (Deployment, StatefulSet, DaemonSet) call
`summon.common.podSpec` which sets up the full pod spec. Batch workloads (Job,
CronJob) call `summon.common.podSpec.body` directly and handle
`serviceAccountName` and `restartPolicy` themselves, since CronJob wraps the
pod template inside `spec.jobTemplate.spec.template` and Job defaults
`restartPolicy` to `Never` while CronJob defaults to `OnFailure`.

### Type-Specific Behavior

Each workload template adds fields specific to its kind:

**Deployment** -- adds `replicas` (omitted when autoscaling is enabled),
`selector.matchLabels`, rolling update strategy support, `hostNetwork`, and
`dnsPolicy`.

**StatefulSet** -- adds `replicas`, `serviceName` (defaults to the release
name), `podManagementPolicy`, and `volumeClaimTemplates` which are rendered by
iterating `workload.volumeClaimTemplates`:

```go
{{- range $name, $volume := $root.Values.workload.volumeClaimTemplates }}
  - metadata:
      name: {{ $name }}
    spec:
      storageClassName: {{ $volume.storageClassName }}
      accessModes:
        - {{ default "ReadWriteOnce" $volume.accessModes }}
      resources:
        requests:
          storage: {{ $volume.size }}
{{- end }}
```

**Job** -- adds `backoffLimit`, `activeDeadlineSeconds`, and sets
`restartPolicy` to `Never` by default.

**CronJob** -- adds `schedule` (required), `concurrencyPolicy`,
`successfulJobsHistoryLimit`, `failedJobsHistoryLimit`, wraps the pod template
inside `spec.jobTemplate.spec.template`, and sets `restartPolicy` to
`OnFailure` by default.

**DaemonSet** -- omits `replicas` entirely (Kubernetes schedules one pod per
node), and adds `updateStrategy` support.

## Unified contentType System

ConfigMaps and secrets both use the same `contentType` field to determine three
things: how the Kubernetes resource data is formatted, whether to mount it as a
volume or inject it as environment variables, and what serialization format to
use. This applies identically to both `configMaps` and `secrets`.

### The Four Content Types

| `contentType` | K8s Data Format | Consumed As | Mount Behavior |
|---------------|-----------------|-------------|----------------|
| `env` | One key per entry in `data:` / `stringData:` | Environment variables via `envFrom` | No volume mount |
| `file` | Single key, raw string value | File at `mountPath/name` | Volume mount with `subPath` |
| `yaml` | Single key, YAML-serialized value | YAML file at `mountPath/name` | Volume mount with `subPath` |
| `json` | Single key, JSON-serialized value | JSON file at `mountPath/name` | Volume mount with `subPath` |

### How contentType Flows Through the Template

The contentType value is read in four independent template subsystems. Here is
the decision path for a ConfigMap entry named `app-config`:

**1. Resource creation** (`storage/config-maps.tpl` and `storage/secrets.tpl`):

```go
{{- $contentType := default "file" $glyphDefinition.definition.contentType }}

{{- if eq $contentType "env" }}
  {{/* Each key-value pair becomes a separate entry in data: */}}
  {{- range $key, $value := $glyphDefinition.definition.content }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}

{{- else }}
  {{/* Single entry: key is the resource name, value is serialized content */}}
  {{ $keyName }}: |
  {{- if eq $contentType "yaml" }}
    {{- $glyphDefinition.definition.content | toYaml | nindent 4 }}
  {{- else if eq $contentType "json" }}
    {{- $glyphDefinition.definition.content | toJson | nindent 4 }}
  {{- else }}
    {{/* contentType: file -- raw content as-is */}}
    {{- $glyphDefinition.definition.content | nindent 4 }}
  {{- end }}
{{- end }}
```

**2. envFrom injection** (`storage/envs.tpl`):

When `contentType` is `env`, the template generates a `configMapRef` or
`secretRef` entry in `envFrom`, which loads all keys as environment variables:

```go
{{- define "summon.common.envs.configMaps" -}}
  {{- range $name, $content := . -}}
    {{- if eq (default "" $content.contentType) "env" }}
  - configMapRef:
      name: {{ $name | replace "." "-" }}
    {{- end }}
  {{- end }}
{{- end -}}
```

**3. Volume definition** (`storage/volumes.tpl`):

When `contentType` is NOT `env`, the template creates a volume referencing the
ConfigMap or Secret:

```go
{{- define "summon.common.volumes.configMaps" -}}
  {{- range $name, $content := . }}
    {{- if ne (default "file" .contentType) "env" }}
- name: {{ (default $name $content.name) | replace "." "-" }}
  configMap:
    name: {{ (default $name $content.name) | replace "." "-" }}
    {{- end }}
  {{- end }}
{{- end -}}
```

**4. Volume mount** (`storage/volume-mounts.tpl`):

When `contentType` is NOT `env`, the template creates a `volumeMount` at
`mountPath/name` with a `subPath` to mount only the specific file:

```go
{{- define "summon.common.volumeMounts.configMaps" -}}
  {{- range $name, $content := . }}
    {{- if ne (default "file" .contentType) "env" }}
- name: {{ (default $name $content.name) | replace "." "-" }}
  mountPath: {{ $content.mountPath }}/{{ (default $name $content.name) }}
  subPath: {{ $fileName }}
    {{- end }}
  {{- end }}
{{- end -}}
```

### contentType: env -- Concrete Example

Given this input:

```yaml
configMaps:
  app-env:
    contentType: env
    location: create
    content:
      DATABASE_HOST: postgres.local
      DATABASE_PORT: "5432"
```

Summon generates:

1. A ConfigMap with each key-value as a separate data entry:

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: app-env
data:
  DATABASE_HOST: "postgres.local"
  DATABASE_PORT: "5432"
```

2. An `envFrom` entry in the container spec:

```yaml
envFrom:
  - configMapRef:
      name: app-env
```

3. No volume mount -- `env` content types are consumed purely through
   environment variable injection.

### contentType: yaml -- Concrete Example

Given this input:

```yaml
configMaps:
  app-config:
    contentType: yaml
    location: create
    name: config.yml
    mountPath: /app/config
    content:
      database:
        host: postgres.local
        port: 5432
      cache:
        host: redis.local
```

Summon generates:

1. A ConfigMap with a single key containing YAML-serialized data:

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: config-yml
data:
  config-yml: |
    cache:
      host: redis.local
    database:
      host: postgres.local
      port: 5432
```

2. A volume referencing the ConfigMap:

```yaml
volumes:
  - name: config-yml
    configMap:
      name: config-yml
```

3. A volume mount placing the file at the specified path:

```yaml
volumeMounts:
  - name: config-yml
    mountPath: /app/config/config.yml
    subPath: config-yml
```

### contentType: json -- Concrete Example

Given this input:

```yaml
configMaps:
  app-settings:
    contentType: json
    location: create
    name: settings.json
    mountPath: /app/settings
    content:
      debug: false
      timeout: 30
```

Summon uses `toJson` instead of `toYaml` to serialize the content:

```yaml
data:
  settings-json: |
    {"debug":false,"timeout":30}
```

The volume and volume mount behavior is identical to `yaml`.

### contentType: file -- Concrete Example

Given this input:

```yaml
secrets:
  tls-cert:
    contentType: file
    location: create
    name: cert.pem
    mountPath: /app/certs
    content: |
      -----BEGIN CERTIFICATE-----
      MIIDXTCCAkWgAwIBAgIJAKLdQVPy90WjMA0GCSqGSIb3DQEBCwUA...
      -----END CERTIFICATE-----
```

The Secret resource uses `stringData` and stores the raw string content:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: cert-pem
stringData:
  cert-pem: |
    -----BEGIN CERTIFICATE-----
    MIIDXTCCAkWgAwIBAgIJAKLdQVPy90WjMA0GCSqGSIb3DQEBCwUA...
    -----END CERTIFICATE-----
```

### Location: create vs. local

The `location` field controls whether summon creates the resource or references
an existing one:

- `location: create` -- summon renders a ConfigMap or Secret resource AND wires
  it into the container (via envFrom or volume mount).
- `location: local` -- summon does NOT create the resource. It only wires it
  into the container, assuming the resource already exists in the cluster
  (created by Vault, Crossplane, or another mechanism).

The orchestrator in `templates/summon.yaml` filters on `location: create`
before calling the resource creation templates:

```go
{{- range $name, $content := .Values.configMaps }}
  {{- if eq $content.location "create" }}
    {{- include "summon.configMap" (list $root $glyph) }}
  {{- end }}
{{- end }}
```

However, the envFrom and volumeMount templates run regardless of `location` --
they wire the reference regardless of who creates the resource.

## Service Auto-Detection

Summon uses a multi-phase decision tree to determine how services are rendered.
The logic lives in two templates: `summon.services.render` (in `service.tpl`)
and `summon.container.ports` (in `_ports.tpl`).

### Service Rendering Decision Tree

The `summon.services.render` template follows this priority order:

```
1. .Values.services (plural map) exists?
   YES --> render multiple named Service resources (Phase 3)

2. .Values.service.enabled is true?
   YES --> check if service.ports is explicitly defined
     2a. service.ports defined?
         YES --> render single Service with those ports
     2b. .Values.containers exists?
         YES --> auto-generate service ports from containers[].ports[]
     2c. Neither?
         Fallback --> render single Service with service.port or default port 80

3. Neither services nor service.enabled?
   --> no Service resources rendered
```

### Container Port Auto-Generation

When `service.enabled` is true but `service.ports` is empty, summon looks at
`containers[].ports[]` to auto-generate the Service port list. This is the
"container-first" approach:

```go
{{- $autoPorts := list }}
{{- range $containerName, $container := .Values.containers }}
  {{- if $container.ports }}
    {{- range $container.ports }}
      {{- $portDef := dict
          "port" .containerPort
          "targetPort" .containerPort
          "name" (.name | default (include "summon.defaultPortName" .containerPort))
          "protocol" (.protocol | default "TCP")
      }}
      {{- $autoPorts = append $autoPorts $portDef }}
    {{- end }}
  {{- end }}
{{- end }}
```

You define ports on the container and summon creates a Service that exposes all
of them:

```yaml
# Input: container-first approach
containers:
  main:
    ports:
      - containerPort: 8080
        name: http
      - containerPort: 9090
        name: metrics

service:
  enabled: true
  type: ClusterIP
  # ports: intentionally omitted -- auto-generated from containers
```

Summon generates a Service with two ports (8080 and 9090) and corresponding
container port entries in the pod spec.

### Port Name Defaults

The `summon.defaultPortName` helper assigns names to unnamed ports:

```go
{{- define "summon.defaultPortName" -}}
{{- if eq (int $port) 80 -}}
http
{{- else -}}
port-{{ $port }}
{{- end -}}
{{- end -}}
```

Only port 80 gets the default name `http`. Every other port gets `port-<number>`
(e.g., `port-8080`, `port-9090`). You should always set explicit port names in
production to avoid confusion.

### Container Port Resolution

The `summon.container.ports` template mirrors the service decision tree for the
container spec:

1. If `containers[].ports[]` is defined, use those directly (container-first).
2. Else if `service.ports[]` is defined, generate container ports from service
   ports using `targetPort` (backward compatible).
3. Else if `services` (plural) is defined, collect unique ports from all
   services.
4. Otherwise, no container ports.

This bidirectional resolution means you can define ports in either place:

- **Container-first**: define ports on `containers[].ports[]`, and Service
  auto-generates from them.
- **Service-first** (backward compatible): define ports on `service.ports[]`,
  and container ports auto-generate from `targetPort`.

## TDD Approach

The `examples/` directory inside `charts/summon/` serves as both the test suite
and living documentation. Each YAML file is a complete set of values that you
feed to `helm template`. The rendered output is compared against expected
snapshots to catch regressions.

### Example File Conventions

Examples follow a naming convention:

- `basic-*.yaml` -- minimal examples of each workload type
- `deployment-with-*.yaml` -- feature-specific deployment examples
- `configmap-*.yaml` -- contentType system examples
- `statefulset-with-*.yaml` -- StatefulSet-specific features
- `test-port-*.yaml` -- port/service auto-detection test cases
- `test-tdd-*.yaml` -- meta examples that demonstrate the TDD workflow itself
- `test-feature-*.yaml` -- red-phase examples for features not yet implemented
- `complex-*.yaml` -- full production-like configurations
- `security-*.yaml` -- security context and policy examples
- `pv-*.yaml` -- persistent volume examples

Each example file is a valid `values.yaml` override. You can render any example
directly:

```bash
helm template my-release charts/summon/ -f charts/summon/examples/basic-deployment.yaml
```

### Test Workflow

You run tests using make targets. The test system renders each example with
`helm template` and compares the output against stored snapshots.

**Run all tests for summon:**

```bash
make test CHART=summon
```

This iterates over every file in `charts/summon/examples/`, renders it, and
diffs the output against the corresponding snapshot. If any output differs from
the snapshot, the test fails with a diff.

**Run a single example:**

```bash
make test CHART=summon EXAMPLE=basic-deployment
```

This renders only `charts/summon/examples/basic-deployment.yaml` and compares
against its snapshot. Use this when you are working on a specific feature and
want fast feedback.

**Regenerate snapshots after intentional changes:**

```bash
make generate-snapshots CHART=summon
```

After you modify template logic and verify the new output is correct, run this
to update all snapshots to match the current rendering. Always review the diff
before regenerating.

**Create a new example for a feature:**

```bash
make create-example CHART=summon EXAMPLE=my-feature
```

This scaffolds a new example file at
`charts/summon/examples/my-feature.yaml` with a minimal template and generates
its initial snapshot.

### TDD Cycle

The TDD workflow follows the standard red-green-refactor cycle, adapted for
Helm chart development:

**Red -- write a failing test:**

```bash
make tdd-red
```

You create an example file that uses a feature that does not exist yet. The
test fails because the template does not render the expected output.

For instance, `test-feature-must-exist.yaml` enables `podDisruptionBudget`
before the feature is implemented:

```yaml
# This test MUST FAIL if the feature does not exist
workload:
  enabled: true
  type: deployment
  replicas: 2

podDisruptionBudget:
  enabled: true
  minAvailable: 1

image:
  repository: nginx
  tag: alpine

service:
  enabled: true
  ports:
    - port: 80
```

When you render this, no PDB resource appears in the output. The snapshot
captures the missing resource, and the test fails against the expected output
that includes a PDB.

**Green -- make it pass:**

```bash
make tdd-green
```

You implement the feature in the template code until the example renders
correctly. For the PDB example, you would add a `summon.pdb` template and
include it in the orchestrator.

**Refactor -- clean up:**

```bash
make tdd-refactor
```

You restructure the template code without changing behavior. The test suite
ensures that refactoring does not break any existing examples.

### Example as Documentation

Each example file doubles as documentation because it shows a complete,
working configuration for a specific feature. When you want to understand how
a feature works, you read the example and render it:

```bash
# See exactly what Kubernetes resources configmap-unified-contenttype generates
helm template test charts/summon/ -f charts/summon/examples/configmap-unified-contenttype.yaml
```

The examples directory is the single source of truth for "what does summon
actually produce?" -- you never need to read template code to understand the
output if you have a matching example.

### Writing a New Test

To add a test for a new feature:

1. Create an example file:

```bash
make create-example CHART=summon EXAMPLE=deployment-with-pdb
```

2. Edit the example with the desired input values:

```yaml
# charts/summon/examples/deployment-with-pdb.yaml
workload:
  enabled: true
  type: deployment
  replicas: 3

podDisruptionBudget:
  enabled: true
  minAvailable: 2

image:
  name: nginx
  tag: alpine

service:
  enabled: true
  ports:
    - port: 80
      name: http
```

3. Run the test to see it fail (red phase):

```bash
make test CHART=summon EXAMPLE=deployment-with-pdb
```

4. Implement the feature in the template code.

5. Run the test to see it pass (green phase):

```bash
make test CHART=summon EXAMPLE=deployment-with-pdb
```

6. Generate the snapshot:

```bash
make generate-snapshots CHART=summon
```

7. Run the full suite to check for regressions:

```bash
make test CHART=summon
```

## Cross-References

- [usage/summon.md](../usage/summon.md) -- User-facing API reference for all summon fields
- [design/architecture.md](architecture.md) -- System overview and data flow
- [design/librarian.md](librarian.md) -- Two-pass processing and how librarian selects summon
- [design/glyphs.md](glyphs.md) -- Glyph anatomy, type system, and submodule distribution
- [design/rendering-pipeline.md](rendering-pipeline.md) -- End-to-end flow from spell YAML to Kubernetes resources
- [design/kaster.md](kaster.md) -- Glyph orchestrator and dispatch logic
- [usage/deploying.md](../usage/deploying.md) -- Running helm template and deploying to clusters
