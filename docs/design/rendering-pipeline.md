# Rendering Pipeline

This document traces the complete end-to-end flow that transforms a spell YAML
file into live Kubernetes resources. You will see the exact Go template code,
the intermediate ArgoCD Application YAML, the rendered manifests, and what
happens after they reach the cluster.

---

## 1. Spell YAML (Input)

Every deployment starts with a spell file in the bookrack. The spell below
deploys an API service with a container image, a Kubernetes Service, a
ServiceAccount, Vault-managed secrets, and Istio routing.

**File**: `bookrack/the-platform-book/services/api-service.yaml`

```yaml
name: api-service
namespace: services

# Workload
workload:
  type: deployment
  replicas: 2

image:
  repository: example-registry/api-service
  tag: "v1.2.3"
  pullPolicy: IfNotPresent

# Resource limits
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Service
service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 8080
      name: http
      targetPort: 8080

# ServiceAccount
serviceAccount:
  enabled: true

# Environment variables
envs:
  APP_ENV: production
  LOG_LEVEL: info

# --- Glyphs (handled by kaster) ---
glyphs:
  vault:
    api-credentials:
      type: secret
      format: env
      path: "chapter"
      keys:
        - api-key
        - api-secret

  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external
      subdomain: api
```

The book index (`bookrack/the-platform-book/index.yaml`) registers summon as
the `defaultTrinket` and kaster as a trinket keyed on `glyphs`:

```yaml
name: the-platform-book

chapters:
  - infrastructure
  - services

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
    external-gateway:
      type: istio-gw
      labels:
        access: external
        default: book
      gateway: istio-system/external-gateway
      baseURL: example.com

    vault-server:
      type: vault
      labels:
        default: book
      url: http://vault.vault.svc:8200
      skipVerify: false
      authPath: kubernetes
      secretPath: kv
```

---

## 2. Librarian Generates an ArgoCD Application

The librarian chart (`librarian/templates/runik.yaml`) is a Helm chart whose
templates iterate over every spell in the bookrack and produce one ArgoCD
`Application` resource per spell. It uses a **two-pass** algorithm.

### 2.1 Pass 1 -- Collect appendix

Pass 1 walks every chapter and every spell file. It merges all `appendix` and
`localAppendix` entries into a single `$globalAppendix` dictionary. This
ensures that any spell can register lexicon entries (gateways, vault servers,
databases) that other spells can consume.

```go
{{/* PASS 1: Collect all appendix from chapters and files */}}
{{- $globalAppendix := deepCopy (default dict $spellbook.appendix) }}
{{- range $chapterName := $spellbook.chapters }}
  {{- $pathChapter := print "bookrack/" $spellbook.name "/" $chapterName "/index.yaml" }}
  {{- if $.Files.Glob $pathChapter }}
    {{- $chapterDef := $.Files.Get $pathChapter | fromYaml }}
    {{- if $chapterDef.appendix }}
      {{- $_ := mergeOverwrite $globalAppendix (deepCopy $chapterDef.appendix) }}
    {{- end }}
  {{- end }}
  {{- range $spellPath, $_ := $.Files.Glob (print "bookrack/" $spellbook.name "/" $chapterName "/*.y*ml") }}
    {{- if not (eq $spellPath (print "bookrack/" $spellbook.name "/" $chapterName "/index.yaml")) }}
      {{- $spellDefinition := ($.Files.Get $spellPath | fromYaml) }}
      {{- if $spellDefinition.appendix }}
        {{- $_ := mergeOverwrite $globalAppendix (deepCopy $spellDefinition.appendix) }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
```

### 2.2 Pass 2 -- Generate Applications with multi-source detection

Pass 2 iterates again and, for each spell file, emits an ArgoCD `Application`.
Two critical operations happen here:

1. **Glyph key stripping**: Keys that match a registered trinket (for example,
   `glyphs` matching kaster's `key: glyphs`) are removed from the values
   passed to the defaultTrinket (summon) and routed to a separate source.

2. **Multi-source construction**: The Application `spec.sources` array is built
   dynamically. Source 1 is always the defaultTrinket (summon) or an external
   chart. Additional sources are added for each trinket key found in the spell.

```go
{{/* Strip trinket keys from values sent to summon */}}
{{- $values := mergeOverwrite (default dict (deepCopy (default dict $defaultTrinket.values))) $spellDefinition }}
{{- $_ := unset $values "runes" }}
{{- $_ := unset $values "appParams" }}
{{- $_ := unset $values "appendix" }}
{{- $_ := unset $values "localAppendix" }}
{{- range $key, $_ := $chapterTrinketsByKey }}
  {{- $_ := unset $values $key }}   {{/* removes "glyphs" from summon values */}}
{{- end }}
```

```go
{{/* For each trinket key found in the spell, add a source */}}
{{- range $trinketKey, $trinket := $chapterTrinketsByKey }}
  {{- if hasKey $spellDefinition $trinketKey }}
    - repoURL: {{ $trinket.repository }}
      path: {{ $trinket.path }}
      targetRevision: {{ $trinket.revision }}
      helm:
        values: |
          glyphs:
          {{- toYaml (index $spellDefinition $trinketKey) | nindent 12 }}
          {{- toYaml $cleanSpellbook | nindent 10 }}
          {{- toYaml (dict "chapter" $chapter) | nindent 10 }}
          lexicon:
          {{- toYaml $lexicon | nindent 12 }}
  {{- end }}
{{- end }}
```

### 2.3 Generated ArgoCD Application

The output of the librarian for the spell above is this Application resource:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service
  namespace: argocd
spec:
  project: the-platform-book
  sources:
    # Source 1: summon (defaultTrinket) -- workload resources
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          name: api-service
          namespace: services
          workload:
            type: deployment
            replicas: 2
          image:
            repository: example-registry/api-service
            tag: "v1.2.3"
            pullPolicy: IfNotPresent
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          service:
            enabled: true
            type: ClusterIP
            ports:
              - port: 8080
                name: http
                targetPort: 8080
          serviceAccount:
            enabled: true
          envs:
            APP_ENV: production
            LOG_LEVEL: info
          spellbook:
            name: the-platform-book
          chapter:
            name: services
          lexicon:
            external-gateway:
              type: istio-gw
              labels:
                access: external
                default: book
              gateway: istio-system/external-gateway
              baseURL: example.com
            vault-server:
              type: vault
              labels:
                default: book
              url: http://vault.vault.svc:8200
              skipVerify: false
              authPath: kubernetes
              secretPath: kv

    # Source 2: kaster -- infrastructure glyphs
    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          glyphs:
            vault:
              api-credentials:
                type: secret
                format: env
                path: "chapter"
                keys:
                  - api-key
                  - api-secret
            istio:
              api-route:
                type: virtualService
                enabled: true
                selector:
                  access: external
                subdomain: api
          spellbook:
            name: the-platform-book
          chapter:
            name: services
          lexicon:
            external-gateway:
              type: istio-gw
              labels:
                access: external
                default: book
              gateway: istio-system/external-gateway
              baseURL: example.com
            vault-server:
              type: vault
              labels:
                default: book
              url: http://vault.vault.svc:8200
              skipVerify: false
              authPath: kubernetes
              secretPath: kv
  destination:
    server: https://kubernetes.default.svc
    namespace: services
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

Notice that `glyphs` does **not** appear in Source 1 (summon) and `image`,
`service`, etc. do **not** appear in Source 2 (kaster). The librarian stripped
each key to its proper source.

---

## 3. ArgoCD Pulls Sources and Runs Helm Template

When ArgoCD syncs this Application, it performs the following for **each
source** in `spec.sources`:

```bash
# Source 1: summon
git clone https://github.com/runik-platform/summon.git
cd summon
helm template api-service . \
  --values <(echo "$SOURCE1_VALUES") \
  --namespace services

# Source 2: kaster
git clone https://github.com/runik-platform/kaster.git
cd kaster
helm template api-service . \
  --values <(echo "$SOURCE2_VALUES") \
  --namespace services
```

ArgoCD merges the resulting manifests from all sources into a single set of
desired resources and applies them to the destination cluster.

---

## 4. Summon Renders the Deployment

Summon is the workload chart. Its entry point is `charts/summon/templates/summon.yaml`.
When `workload.enabled` is `true`, it dispatches to the workload type template:

```go
{{- if .Values.workload.enabled }}
{{- include ( printf "summon.workload.%s" .Values.workload.type ) . }}
{{- end -}}
```

For `workload.type: deployment`, this calls the `summon.workload.deployment`
template defined in `charts/glyphs/summon/templates/workload/deployment/deployment.tpl`:

```go
{{- define "summon.workload.deployment" -}}
{{- $root := . -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.name" $root }}
  labels:
    {{- include "common.all.labels" $root | nindent 4 }}
spec:
  {{- if not $root.Values.autoscaling.enabled }}
  replicas: {{ default 1 $root.Values.workload.replicas }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" $root | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common.selectorLabels" $root | nindent 8 }}
    spec:
      {{- include "summon.common.podSpec" $root | nindent 6 }}
{{- end -}}
```

The `summon.common.podSpec` helper (in `_pod-spec.tpl`) generates the full pod
spec including `serviceAccountName`, `containers`, `volumes`, and
`securityContext`. The container template (`_container.tpl`) resolves the image
reference, pull policy, probes, resources, and environment variables.

Summon also renders a **Service** (via `summon.services.render`), a
**ServiceAccount** (via `summon.serviceAccount`), and optionally an
**HorizontalPodAutoscaler** (via `summon.autoscaling`).

### 4.1 Rendered Deployment YAML

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: api-service
      app.kubernetes.io/instance: api-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-service
        app.kubernetes.io/instance: api-service
    spec:
      serviceAccountName: api-service
      containers:
        - name: api-service-main
          image: example-registry/api-service:v1.2.3
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          env:
            - name: APP_ENV
              value: production
            - name: LOG_LEVEL
              value: info
          ports:
            - containerPort: 8080
              name: http
              protocol: TCP
```

### 4.2 Rendered Service YAML

The `summon.service` template generates:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-service
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  type: ClusterIP
  ports:
    - port: 8080
      protocol: TCP
      name: http
      targetPort: 8080
  selector:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
```

### 4.3 Rendered ServiceAccount YAML

The `summon.serviceAccount` template generates:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-service
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
```

---

## 5. Kaster Renders VaultSecret

Kaster is the glyph orchestrator. Its entry point
(`charts/kaster/templates/kaster.yaml`) iterates over all glyph sub-charts and
dispatches each glyph entry to the matching template by constructing the
include name from the sub-chart name and the glyph's `type` field:

```go
{{- if $root.Values.glyphs }}
  {{- range $chartName, $_ := $root.Subcharts }}
    {{- range $glyphName, $glyph := index $root.Values.glyphs $chartName }}
      {{- $glyphWithName := merge $glyph (dict "name" $glyphName) }}
      {{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
    {{- end }}
  {{- end }}
{{- end }}
```

For `glyphs.vault.api-credentials` with `type: secret`, kaster calls:

```
include "vault.secret" (list $root $glyphWithName)
```

### 5.1 Runic Indexer lookup

The `vault.secret` template immediately queries the lexicon via the Runic
Indexer to find vault server configuration. The Runic Indexer
(`charts/glyphs/runic-system/templates/_runic-indexer.tpl`) performs label-based
matching with AND logic and a fallback priority chain:

1. **Exact match**: All selectors match a lexicon entry's labels.
2. **Book default**: Entry with `labels.default: book` when no selectors match.
3. **Chapter default**: Entry with `labels.default: chapter` in the same chapter.

```go
{{- define "vault.secret" -}}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1 }}
{{- $vaultServer := get (include "runic-system.runic-indexer"
    (list $root.Values.lexicon
          (default dict $glyphDefinition.selector)
          "vault"
          $root.Values.chapter.name)
    | fromJson) "results" }}
{{- range $vaultConf := $vaultServer }}
```

Since our glyph has no `selector`, the indexer falls back to the book-default
vault entry (`vault-server` with `labels.default: book`).

### 5.2 Secret path resolution

The path is resolved through `common.secretPath` (called via
`vault.secretPath` and its wrapper `generateSecretPath`). For
`path: "chapter"`, the resulting Vault path is:

```
kv/data/the-platform-book/services/publics/api-credentials
```

The `/data` prefix is injected by `vault.secretPath` because Vault KV v2
requires it for read operations.

### 5.3 Rendered VaultSecret YAML

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: api-credentials
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  refreshPeriod: 3m0s
  vaultSecretDefinitions:
    - name: secret
      requestType: GET
      path: kv/data/the-platform-book/services/publics/api-credentials
      authentication:
        path: kubernetes
        role: api-service
        serviceAccount:
          name: api-service
      connection:
        address: http://vault.vault.svc:8200
        tLSConfig:
          skipVerify: false
  output:
    name: api-credentials
    labels:
      app.kubernetes.io/name: api-service
      app.kubernetes.io/instance: api-service
      app.kubernetes.io/managed-by: Helm
      app.kubernetes.io/part-of: the-platform-book
    stringData:
      API_KEY: '{{ .secret.api-key }}'
      API_SECRET: '{{ .secret.api-secret }}'
    type: Opaque
```

The `stringData` values contain Go template expressions (`{{ .secret.api-key }}`)
that the Vault Operator evaluates at runtime, substituting actual secret values
fetched from Vault.

---

## 6. Kaster Renders VirtualService

For `glyphs.istio.api-route` with `type: virtualService`, kaster calls:

```
include "istio.virtualService" (list $root $glyphWithName)
```

### 6.1 Runic Indexer gateway lookup

The VirtualService template queries the lexicon for an `istio-gw` entry
matching the glyph's selector:

```go
{{- define "istio.virtualService" }}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1 }}
{{- if $glyphDefinition.enabled }}
{{- $gateways := get (include "runic-system.runic-indexer"
    (list $root.Values.lexicon
          (default dict $glyphDefinition.selector)
          "istio-gw"
          $root.Values.chapter.name)
    | fromJson) "results" }}
{{- range $gateway := $gateways }}
```

The selector `access: external` matches the lexicon entry `external-gateway`
(which has `labels.access: external`). The indexer returns the gateway
configuration including `gateway: istio-system/external-gateway` and
`baseURL: example.com`.

### 6.2 Host and route construction

The template constructs the host by combining the glyph's `subdomain` with the
gateway's `baseURL`:

```go
hosts:
  - {{ if $glyphDefinition.subdomain }}{{ $glyphDefinition.subdomain }}.{{ end }}{{ $gateway.baseURL }}
```

This produces `api.example.com`. When no custom `httpRules` are provided, the
template creates a default rule matching the prefix `/<common.name>` with a
rewrite to `/`.

### 6.3 Rendered VirtualService YAML

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-service-external-gateway
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  hosts:
    - api.example.com
  gateways:
    - istio-system/external-gateway
  http:
    - match:
        - uri:
            prefix: /api-service
      rewrite:
        uri: /
      route:
        - destination:
            host: api-service.services.svc.cluster.local
            port:
              number: 80
```

---

## 7. Kubernetes Applies -- Controllers React

Once ArgoCD applies the merged manifests, three independent controller loops
take over:

### 7.1 Deployment controller

The Kubernetes Deployment controller sees the new `Deployment` resource and:

1. Creates a `ReplicaSet` matching the pod template spec.
2. The ReplicaSet controller creates 2 `Pods` (matching `replicas: 2`).
3. The kubelet on each node pulls the `example-registry/api-service:v1.2.3`
   image and starts the container.
4. The `Service` object directs traffic to pods matching
   `app.kubernetes.io/name: api-service`.

### 7.2 Vault Operator

The Vault Config Operator (`redhatcop.redhat.io/v1alpha1`) watches for
`VaultSecret` resources. When it sees `api-credentials`:

1. It authenticates to Vault at `http://vault.vault.svc:8200` using Kubernetes
   auth (path `kubernetes`, role `api-service`, service account `api-service`).
2. It reads the secret at `kv/data/the-platform-book/services/publics/api-credentials`.
3. It creates a native Kubernetes `Secret` named `api-credentials` in the
   `services` namespace, populating `API_KEY` and `API_SECRET` with the values
   from Vault.
4. Every 3 minutes (`refreshPeriod: 3m0s`), it re-reads the Vault path and
   updates the Secret if values have changed.

### 7.3 Istio control plane

The Istio control plane (istiod) watches for `VirtualService` resources. When
it sees `api-service-external-gateway`:

1. It validates the VirtualService against the referenced gateway
   `istio-system/external-gateway`.
2. It pushes updated Envoy proxy configuration (via xDS) to all sidecar proxies
   and the gateway's Envoy instances.
3. Requests arriving at `api.example.com` with the prefix `/api-service` are
   routed to `api-service.services.svc.cluster.local:80` with the URI rewritten
   to `/`.

---

## Complete End-to-End Example

### Input spell

```yaml
# bookrack/the-platform-book/services/api-service.yaml
name: api-service
namespace: services

workload:
  type: deployment
  replicas: 2

image:
  repository: example-registry/api-service
  tag: "v1.2.3"
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

service:
  enabled: true
  type: ClusterIP
  ports:
    - port: 8080
      name: http
      targetPort: 8080

serviceAccount:
  enabled: true

envs:
  APP_ENV: production
  LOG_LEVEL: info

glyphs:
  vault:
    api-credentials:
      type: secret
      format: env
      path: "chapter"
      keys:
        - api-key
        - api-secret

  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external
      subdomain: api
```

### Final Kubernetes resources

Five resources are produced from this single spell file.

**1. Deployment** (from summon, Source 1):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: services
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: api-service
      app.kubernetes.io/instance: api-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-service
        app.kubernetes.io/instance: api-service
    spec:
      serviceAccountName: api-service
      containers:
        - name: api-service-main
          image: example-registry/api-service:v1.2.3
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          env:
            - name: APP_ENV
              value: production
            - name: LOG_LEVEL
              value: info
          ports:
            - containerPort: 8080
              name: http
              protocol: TCP
```

**2. Service** (from summon, Source 1):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-service
  namespace: services
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  type: ClusterIP
  ports:
    - port: 8080
      protocol: TCP
      name: http
      targetPort: 8080
  selector:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
```

**3. ServiceAccount** (from summon, Source 1):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-service
  namespace: services
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
```

**4. VaultSecret** (from kaster, Source 2):

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: api-credentials
  namespace: services
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  refreshPeriod: 3m0s
  vaultSecretDefinitions:
    - name: secret
      requestType: GET
      path: kv/data/the-platform-book/services/publics/api-credentials
      authentication:
        path: kubernetes
        role: api-service
        serviceAccount:
          name: api-service
      connection:
        address: http://vault.vault.svc:8200
        tLSConfig:
          skipVerify: false
  output:
    name: api-credentials
    labels:
      app.kubernetes.io/name: api-service
      app.kubernetes.io/instance: api-service
      app.kubernetes.io/managed-by: Helm
      app.kubernetes.io/part-of: the-platform-book
    stringData:
      API_KEY: '{{ .secret.api-key }}'
      API_SECRET: '{{ .secret.api-secret }}'
    type: Opaque
```

**5. VirtualService** (from kaster, Source 2):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-service-external-gateway
  namespace: services
  labels:
    app.kubernetes.io/name: api-service
    app.kubernetes.io/instance: api-service
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: the-platform-book
spec:
  hosts:
    - api.example.com
  gateways:
    - istio-system/external-gateway
  http:
    - match:
        - uri:
            prefix: /api-service
      rewrite:
        uri: /
      route:
        - destination:
            host: api-service.services.svc.cluster.local
            port:
              number: 80
```

### Summary of the flow

```
spell YAML
  |
  v
librarian (Pass 1: collect appendix, Pass 2: generate Applications)
  |
  v
ArgoCD Application (multi-source: summon + kaster)
  |
  +---> Source 1: summon chart
  |       |
  |       +---> Deployment
  |       +---> Service
  |       +---> ServiceAccount
  |
  +---> Source 2: kaster chart
          |
          +---> VaultSecret  (vault glyph -> runicIndexer -> vault.secret template)
          +---> VirtualService (istio glyph -> runicIndexer -> istio.virtualService template)
  |
  v
Kubernetes API server
  |
  +---> Deployment controller -> ReplicaSet -> Pods
  +---> Vault Operator -> reads Vault -> creates K8s Secret
  +---> Istio control plane -> pushes Envoy config -> routes traffic
```

---

## Cross-References

- **[../usage/spells.md](../usage/spells.md)** -- Spell types, fields, and user-facing examples.
- **[../usage/summon.md](../usage/summon.md)** -- Workload configuration, probes, volumes, env vars.
- **[../usage/lexicon.md](../usage/lexicon.md)** -- Lexicon entries, appendix registration, Runic Indexer usage.
- **[../usage/runes.md](../usage/runes.md)** -- Adding external Helm charts via runes.
- **[../usage/bookrack.md](../usage/bookrack.md)** -- Book/chapter structure, merge hierarchy.
- **[../usage/deploying.md](../usage/deploying.md)** -- ArgoCD sync behavior and debugging.
- **[README.md](README.md)** -- Design document index, reading order.
