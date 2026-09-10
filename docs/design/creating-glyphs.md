# Creating Glyphs

This guide walks you through creating a custom glyph from scratch, testing it with kaster, and distributing it for use in spells. By the end, you will have a working glyph with templates, examples, and snapshot tests.

## Prerequisites

Before you begin, make sure you understand these concepts:

- **Glyph**: A Helm subchart containing Go templates that generate Kubernetes resources. Glyphs live canonically under `charts/glyphs/` and are loaded by kaster as subcharts through `charts/kaster/charts/`, which is a git submodule tracking the same `glyphs.git` repository.
- **Kaster**: The glyph orchestrator. It iterates over `glyphs:` values, looks up each glyph by chart name, and calls `include "chartName.typeName"` to dispatch rendering.
- **Type**: Each glyph entry in a spell has a `type` field. Kaster uses it to call the correct template: `{{ include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}`.

## Step 1: Create the Directory Structure

Every glyph follows a standard layout with templates and examples:

```bash
mkdir -p charts/glyphs/my-glyph/{templates,examples}
```

This creates:

```
charts/glyphs/my-glyph/
  templates/       # Go template files (.tpl)
  examples/        # Test input YAML files for snapshot testing
```

Because `charts/kaster/charts` is a git submodule of the same `glyphs.git`
repository, your new glyph becomes visible to kaster once the change is
committed and pushed in the canonical `charts/glyphs/` submodule and the
kaster submodule reference is bumped. For local development, that kaster bump
is enough to test the `glyphs:` dispatcher end to end. It is **not** the full
distribution workflow: a release must also bump summon, microspell, tarot and
covenant as described in Step 7.

## Step 2: Create Chart.yaml

Create `charts/glyphs/my-glyph/Chart.yaml` with `apiVersion: v2`:

```yaml
apiVersion: v2
name: my-glyph
version: 1.0.0
description: My custom glyph for Runik Platform
```

The `name` field is critical -- it must match the directory name and the key you use under `glyphs:` in spells. When a spell contains `glyphs.my-glyph`, kaster looks for a subchart named `my-glyph` and dispatches to its templates.

## Step 3: Create the Template

Create `charts/glyphs/my-glyph/templates/_my-glyph.tpl`. This file contains one or more `define` blocks, each representing a type that kaster can dispatch to.

### The define/end Pattern

Every glyph template follows the same pattern:

```go
{{- define "my-glyph.myType" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $definition.name }}
data:
  config: {{ $definition.config | quote }}
{{- end -}}
```

### How It Works

**Template name**: The `define` block is named `"chartName.typeName"` -- in this case `"my-glyph.myType"`. Kaster constructs this name dynamically from the glyph chart name and the `type` field in the spell:

```go
{{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
```

So when a spell contains `type: myType` under the `my-glyph` key, kaster calls `include "my-glyph.myType"`.

**Parameter list**: The template receives a list of two elements:

| Parameter | Access | Contents |
|-----------|--------|----------|
| `$root` | `index . 0` | The full Helm root context. Contains `.Values.lexicon`, `.Values.spellbook`, `.Values.chapter`, `.Release`, and all other Helm objects. Use this to access the runic indexer, common labels, and shared configuration. |
| `$definition` | `index . 1` | The glyph configuration from the spell, with `name` automatically injected by kaster (set to the YAML key name). Contains every field the user wrote under this glyph entry. |

**The `---` separator**: Always emit a YAML document separator before each resource. Kaster concatenates output from all glyphs, and the separator ensures valid multi-document YAML.

### Using Common Helpers

You have access to the same helpers available in all runik charts:

```go
{{- define "my-glyph.myType" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ default (include "common.name" $root) $definition.name }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
    {{- with $definition.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $definition.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
data:
  config: {{ $definition.config | quote }}
{{- end -}}
```

### Using the Runic Indexer

If your glyph needs to discover infrastructure (gateways, issuers, vault servers, etc.), use the runic indexer:

```go
{{- $results := get (include "runic-system.runic-indexer" (list $root.Values.lexicon (default dict $definition.selector) "my-type" $root.Values.chapter.name) | fromJson) "results" }}
{{- range $result := $results }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $definition.name }}-{{ $result.name }}
data:
  endpoint: {{ $result.endpoint }}
{{- end }}
```

The indexer takes four arguments: the lexicon, selectors, the infrastructure type to search for, and the current chapter name. It returns a list of matching entries.

### Multiple Types in One Glyph

A single glyph chart can define multiple types. Create separate `define` blocks -- either in the same file or in separate `.tpl` files under `templates/`:

```go
{{- define "my-glyph.typeA" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $definition.name }}
data:
  value: {{ $definition.value | quote }}
{{- end -}}

{{- define "my-glyph.typeB" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ $definition.name }}
type: Opaque
stringData:
  key: {{ $definition.key | quote }}
{{- end -}}
```

Users can then reference either type:

```yaml
glyphs:
  my-glyph:
    config-entry:
      type: typeA
      value: "hello"
    secret-entry:
      type: typeB
      key: "s3cr3t"
```

## Step 4: Create an Example File

Create `charts/glyphs/my-glyph/examples/basic.yaml`. This file serves as both documentation and test input for snapshot testing. It must provide all the values kaster needs to render the template, including `spellbook`, `chapter`, and any `lexicon` entries your template requires.

```yaml
# Basic my-glyph example
# Shows how to create a simple ConfigMap via the my-glyph glyph

spellbook:
  name: my-app
chapter:
  name: production

glyphs:
  my-glyph:
    my-config:
      type: myType
      config: "hello world"
```

### Example Structure

Study existing examples to understand the pattern. Every example file provides:

| Section | Purpose |
|---------|---------|
| `spellbook` | Book context (name, subdomain, etc.) |
| `chapter` | Chapter context (name, subdomain, etc.) |
| `lexicon` | Infrastructure entries if the template uses the runic indexer |
| `glyphs` | The glyph configuration to test |

If your template uses the runic indexer, you must include matching lexicon entries:

```yaml
spellbook:
  name: my-app
chapter:
  name: production

lexicon:
  my-infra-entry:
    name: my-infra-entry
    type: my-type
    endpoint: https://infra.example.com
    labels:
      environment: production
      default: book

glyphs:
  my-glyph:
    my-resource:
      type: myType
      selector:
        environment: production
      config: "hello world"
```

## Step 5: Create Expected Output for Snapshot Testing

Snapshot testing validates that your template produces the expected Kubernetes resources. Generate the expected output by rendering kaster with your example file:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/my-glyph/examples/basic.yaml
```

Review the output. If it matches what you expect, save it as the snapshot baseline. If it does not, adjust your template and re-render until the output is correct.

The expected output for the basic example above would look like:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-config
data:
  config: "hello world"
```

## Step 6: Test via Kaster

The only valid way to test a glyph is through kaster, because kaster is the dispatcher that calls your template at runtime. Do not test templates in isolation -- always render them through kaster to verify the full dispatch chain.

```bash
make glyphs my-glyph
```

This target runs kaster with each example file in `charts/glyphs/my-glyph/examples/` and compares the output against saved snapshots.

You can also render manually for debugging:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/my-glyph/examples/basic.yaml
```

If the output is empty, check:

1. Your `Chart.yaml` `name` field matches the directory name and the `glyphs:` key.
2. Your `define` block name follows the `"chartName.typeName"` convention.
3. The `type` field in the example matches the type in the `define` block name.
4. The kaster submodule reference is up to date with the glyph commit.

## Step 7: Distribute the Glyph

Once the glyph renders and passes tests locally in `charts/glyphs/`, commit and
push it there and merge its reviewed PR into `glyphs/upstream`. That merge is
the release event. The operational `glyphs-release` Tarot reading:

1. Locks Glyph releases so cascades cannot overlap.
2. Checks out the merged Glyph commit in all five consumers, regenerates the
   aggregate snapshots, and runs `make test all` against the prospective tree.
3. Creates an audit PR in each direct consumer and force-merges it using the
   release identity after the aggregate test succeeds.
4. Re-clones Runik at the latest `upstream`, pins Glyphs plus all five merged
   consumers, re-runs the complete test suite, and creates and force-merges the
   final aggregate PR.

No approval after the original Glyph PR is part of the normal release path.
Every generated branch and PR is keyed by the approved Glyph commit SHA, so a
retry is idempotent and resumes from the first consumer that is not yet pinned.

If the release reading is unavailable, use this recovery checklist:

1. Bump the `charts/` submodule in all five direct consumers:
   - `charts/kaster/`
   - `charts/summon/`
   - `charts/trinkets/microspell/`
   - `charts/trinkets/tarot/`
   - `covenant/`
2. Validate both dispatch paths: `glyphs:` through kaster and top-level glyph
   keys through summon. Render the remaining consumers to detect helper or
   template compatibility problems.
3. Commit, push and merge each consumer bump. This is normally done by Tarot.
4. In the top-level Runik repository, bump `charts/glyphs/` plus all five
   consumer submodules. Merge this aggregator change last. This is also
   normally done by Tarot.

Do not omit microspell: it consumes `glyphs.git` directly through
`charts/trinkets/microspell/charts`, even though it reuses many summon
templates by name.

## Step 8: Register in Book index.yaml

**You do not need to register glyphs in the book index.yaml.** Kaster and summon both ship the glyph once the submodule references are up to date. The kaster trinket is already registered in the book index:

```yaml
# bookrack/production/index.yaml
trinkets:
  kaster:
    key: glyphs
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: upstream
```

From that point, a spell triggers the glyph through whichever dispatcher applies:

- When the spell uses summon (no `chart:`/`path:`), the infrastructure goes at the **top level** of the spell (e.g. `vault:`, `istio:`). Summon's internal dispatcher renders it inline — no separate kaster source is emitted.
- When the spell uses an external chart (`chart:` + `repository:` or `path:`), the infrastructure goes under the `glyphs:` key. Librarian routes it to kaster as a **separate** ArgoCD source.

Both dispatchers use the same template naming convention (`<chart>.<type>`), so a single glyph template works from both. See [docs/usage/glyphs.md](../usage/glyphs.md) for the spell-author view.

**Exception -- new trinket keys**: If you are creating an entirely new trinket (not a glyph), you must register it in the book `index.yaml` under `trinkets:` with its own key. See the trinkets documentation for details.

---

## Complete Example: Creating a Redis Glyph

This section walks through creating a `redis` glyph that generates a Redis Deployment and Service from a simple spell entry.

### 1. Create the Directory

```bash
mkdir -p charts/glyphs/redis/{templates,examples}
```

### 2. Create Chart.yaml

```yaml
# charts/glyphs/redis/Chart.yaml
apiVersion: v2
name: redis
version: 1.0.0
description: Redis deployment glyph for Runik Platform
```

### 3. Create the Template

```go
{{/* charts/glyphs/redis/templates/_redis.tpl */}}

{{/*Runik Platform
Redis glyph: creates a Redis Deployment and Service.

Parameters:
- $root: Chart root context (index . 0)
- $definition: Redis configuration object (index . 1)

Required Configuration:
- definition.name: resource name (auto-injected by kaster)

Optional Configuration:
- definition.image: Redis image (default: redis:7-alpine)
- definition.replicas: number of replicas (default: 1)
- definition.port: Redis port (default: 6379)
- definition.maxMemory: Redis maxmemory setting (default: 256mb)
- definition.maxMemoryPolicy: eviction policy (default: allkeys-lru)
- definition.persistence.enabled: enable PVC (default: false)
- definition.persistence.size: PVC size (default: 1Gi)
- definition.namespace: target namespace

Usage: {{- include "redis.standalone" (list $root $glyph) }}
*/}}

{{- define "redis.standalone" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
{{- $image := default "redis:7-alpine" $definition.image -}}
{{- $port := default 6379 $definition.port -}}
{{- $replicas := default 1 $definition.replicas -}}
{{- $maxMemory := default "256mb" $definition.maxMemory -}}
{{- $maxMemoryPolicy := default "allkeys-lru" $definition.maxMemoryPolicy -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $definition.name }}
  {{- if $definition.namespace }}
  namespace: {{ $definition.namespace }}
  {{- end }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
    app.kubernetes.io/component: redis
    {{- with $definition.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $definition.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  replicas: {{ $replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $definition.name }}
      app.kubernetes.io/component: redis
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $definition.name }}
        app.kubernetes.io/component: redis
    spec:
      containers:
        - name: redis
          image: {{ $image }}
          ports:
            - containerPort: {{ $port }}
              name: redis
              protocol: TCP
          args:
            - redis-server
            - --maxmemory
            - {{ $maxMemory }}
            - --maxmemory-policy
            - {{ $maxMemoryPolicy }}
          resources:
            {{- if $definition.resources }}
            {{- toYaml $definition.resources | nindent 12 }}
            {{- else }}
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 512Mi
            {{- end }}
          {{- if and $definition.persistence $definition.persistence.enabled }}
          volumeMounts:
            - name: redis-data
              mountPath: /data
          {{- end }}
      {{- if and $definition.persistence $definition.persistence.enabled }}
      volumes:
        - name: redis-data
          persistentVolumeClaim:
            claimName: {{ $definition.name }}-data
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $definition.name }}
  {{- if $definition.namespace }}
  namespace: {{ $definition.namespace }}
  {{- end }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  selector:
    app.kubernetes.io/name: {{ $definition.name }}
    app.kubernetes.io/component: redis
  ports:
    - port: {{ $port }}
      targetPort: {{ $port }}
      name: redis
      protocol: TCP
{{- if and $definition.persistence $definition.persistence.enabled }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $definition.name }}-data
  {{- if $definition.namespace }}
  namespace: {{ $definition.namespace }}
  {{- end }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ default "1Gi" $definition.persistence.size }}
  {{- with $definition.persistence.storageClassName }}
  storageClassName: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}
```

### 4. Create Example Files

**Basic example** -- `charts/glyphs/redis/examples/basic-standalone.yaml`:

```yaml
# Basic Redis Standalone Example
# Shows how to deploy a simple Redis instance as a cache

spellbook:
  name: my-app
chapter:
  name: production

glyphs:
  redis:
    session-cache:
      type: standalone
      maxMemory: "128mb"
      maxMemoryPolicy: allkeys-lru
```

**Advanced example with persistence** -- `charts/glyphs/redis/examples/persistent-redis.yaml`:

```yaml
# Persistent Redis Example
# Shows Redis with persistent storage and custom resources

spellbook:
  name: my-app
chapter:
  name: production

glyphs:
  redis:
    data-store:
      type: standalone
      image: redis:7.2-alpine
      port: 6379
      maxMemory: "1gb"
      maxMemoryPolicy: volatile-lfu
      persistence:
        enabled: true
        size: 10Gi
        storageClassName: fast-ssd
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
        limits:
          cpu: "1"
          memory: 2Gi
```

### 5. Test Through Kaster

Render the basic example:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/redis/examples/basic-standalone.yaml
```

Expected output:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: session-cache
  labels:
    app.kubernetes.io/component: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: session-cache
      app.kubernetes.io/component: redis
  template:
    metadata:
      labels:
        app.kubernetes.io/name: session-cache
        app.kubernetes.io/component: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
              name: redis
              protocol: TCP
          args:
            - redis-server
            - --maxmemory
            - 128mb
            - --maxmemory-policy
            - allkeys-lru
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: session-cache
  labels:
    app.kubernetes.io/component: redis
spec:
  selector:
    app.kubernetes.io/name: session-cache
    app.kubernetes.io/component: redis
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
      protocol: TCP
```

### 6. Use in a Spell

Once tested, use the glyph in any spell:

```yaml
# With a summon workload (glyph keys at top level)
name: api-service
image: myorg/api:v2.0
service:
  enabled: true

redis:
  session-cache:
    type: standalone
    maxMemory: "256mb"
```

```yaml
# With an external chart (glyph keys inside glyphs: wrapper)
name: nginx-app
repository: https://charts.bitnami.com/bitnami
chart: nginx
revision: 18.2.6

values:
  replicaCount: 2

glyphs:
  redis:
    cache:
      type: standalone
```

```yaml
# Infrastructure-only spell (no chart, no path -- defaultTrinket runs)
name: shared-redis
namespace: infrastructure

workload:
  enabled: false

redis:
  shared-cache:
    type: standalone
    persistence:
      enabled: true
      size: 50Gi
```

---

## TDD Workflow

Follow a test-driven development cycle when building glyphs. This ensures your template produces correct output before you integrate it into spells.

### Red: Write the Example First

Start by writing the example file that describes the input your glyph should accept:

```yaml
# charts/glyphs/redis/examples/basic-standalone.yaml
spellbook:
  name: my-app
chapter:
  name: production

glyphs:
  redis:
    session-cache:
      type: standalone
      maxMemory: "128mb"
```

At this point, there is no template yet. Running kaster with this example produces no output or an error -- the test is red.

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/redis/examples/basic-standalone.yaml
# Error or empty output: template "redis.standalone" not defined
```

### Green: Implement the Template

Create the template that satisfies the example:

```go
{{- define "redis.standalone" -}}
{{- $root := index . 0 -}}
{{- $definition := index . 1 -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $definition.name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ $definition.name }}
  template:
    metadata:
      labels:
        app: {{ $definition.name }}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          args:
            - redis-server
            - --maxmemory
            - {{ default "256mb" $definition.maxMemory }}
{{- end -}}
```

Now render again:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/redis/examples/basic-standalone.yaml
```

The output contains a Deployment -- the test is green.

### Refactor: Generate Snapshot and Iterate

Save the output as the snapshot baseline:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/redis/examples/basic-standalone.yaml \
  > charts/glyphs/redis/examples/basic-standalone.snapshot.yaml
```

Now iterate on the template. Add labels, Service, PVC, resource defaults, and other features. After each change, re-render and compare against the snapshot:

```bash
helm template test-release ./charts/kaster \
  --values charts/glyphs/redis/examples/basic-standalone.yaml \
  | diff - charts/glyphs/redis/examples/basic-standalone.snapshot.yaml
```

When the output matches your expectations, update the snapshot. Run `make glyphs redis` to validate all examples against their snapshots.

### Add More Examples

Write additional examples that exercise edge cases and advanced features:

```bash
# Test persistence
charts/glyphs/redis/examples/persistent-redis.yaml

# Test custom resources and ports
charts/glyphs/redis/examples/custom-resources.yaml

# Test with lexicon integration (if applicable)
charts/glyphs/redis/examples/lexicon-lookup.yaml
```

Each example should have a corresponding snapshot. The full test suite runs all examples through kaster and compares output.

---

## Template Conventions

Follow these conventions to keep glyphs consistent across the project.

### File Naming

| File | Convention | Example |
|------|-----------|---------|
| Template file | `_chartName.tpl` or `typeName.tpl` | `_redis.tpl`, `certificate.tpl` |
| Example file | `descriptive-name.yaml` | `basic-standalone.yaml`, `persistent-redis.yaml` |
| Chart definition | `Chart.yaml` | Always `Chart.yaml` |

### Template Header

Start every template file with a license header and documentation comment:

```go
{{/*Runik Platform
Copyright (C) 2023 namenmalkv@gmail.com
SPDX-License-Identifier: AGPL-3.0-only

redis.standalone creates a Redis Deployment and Service.

Parameters:
- $root: Chart root context (index . 0)
- $definition: Redis configuration object (index . 1)

Usage: {{- include "redis.standalone" (list $root $glyph) }}
*/}}
```

### Parameter Naming

Use `$root` for the chart context and `$definition` (or `$glyphDefinition`) for the glyph configuration. Both conventions exist in the codebase -- pick one and stay consistent within your glyph.

### Default Values

Use Go template `default` for optional fields rather than requiring them:

```go
{{- $image := default "redis:7-alpine" $definition.image -}}
{{- $port := default 6379 $definition.port -}}
```

### Conditional Blocks

Use `with` for optional map/list fields and `if` for boolean toggles:

```go
{{- with $definition.annotations }}
annotations:
  {{- toYaml . | nindent 4 }}
{{- end }}

{{- if $definition.persistence.enabled }}
volumeMounts:
  - name: data
    mountPath: /data
{{- end }}
```

---

## Cross-References

- **design/kaster.md** -- Kaster dispatch logic, how `chartName.typeName` resolution works
- **design/glyphs.md** -- Glyph anatomy, type system, submodule distribution model
- **design/lexicon.md** -- Runic indexer, selection algorithm, query format for lexicon lookups
- **design/rendering-pipeline.md** -- End-to-end flow from spell to Kubernetes resources
- **design/creating-trinkets.md** -- Creating a custom trinket (different from glyphs)
- **usage/spells.md** -- How glyph keys appear in spells and trigger kaster
- **usage/debugging.md** -- Debugging glyph rendering issues and kaster dispatch
