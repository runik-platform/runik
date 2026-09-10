# Creating Trinkets

This guide walks you through building a custom trinket for Runik Platform. By the end, you will have a standalone Helm chart registered in your book, automatically triggered by a key in any spell, and deployed as its own ArgoCD source.

## When to Create a Trinket vs a Glyph

Before you start, make sure a trinket is the right abstraction. Runik has two extension mechanisms, and they serve different purposes.

### Glyphs

A glyph adds infrastructure resources to any spell via kaster. When you define a glyph, you are writing a Helm template library -- a set of named templates that kaster dispatches to based on type. Glyphs produce resources like VaultSecret, VirtualService, Certificate, or PeerAuthentication. They are never deployed on their own; kaster renders them as part of a multi-source Application alongside summon or an external chart.

Use a glyph when:

- You want to attach infrastructure to existing spells without changing the primary chart.
- The output is one or two Kubernetes resources that supplement a workload.
- The resources are generic enough to apply to any spell (secrets, networking, TLS).

Examples: `vault` (VaultSecret, VaultPolicy), `istio` (VirtualService, DestinationRule, Gateway), `cert-manager` (Certificate, ClusterIssuer).

### Trinkets

A trinket is a standalone Helm chart that becomes its own ArgoCD source. It has its own `Chart.yaml`, `values.yaml`, and `templates/` directory. When the Librarian detects the trinket's registered key in a spell, it adds the trinket chart as an additional source in the generated ArgoCD Application and passes the value of that key as Helm values.

Use a trinket when:

- You need a full chart with its own templates, helpers, and rendering logic.
- The domain is complex enough that a single glyph template would be unwieldy.
- You want opinionated defaults and conventions that go beyond what summon provides.
- The output is multiple related Kubernetes resources that form a cohesive unit.

Examples: `microspell` (opinionated microservice deployment) and `tarot`
(Argo Workflow composition). Covenant is a sibling IAM renderer, not a
key-triggered trinket.

### Decision Checklist

| Question | Glyph | Trinket |
|----------|-------|---------|
| Does it produce 1-2 supplementary resources? | Yes | No |
| Does it need its own template helpers? | No | Yes |
| Does it wrap an entire domain with conventions? | No | Yes |
| Should it work as an add-on to any chart? | Yes | No |
| Does it need its own `values.yaml` with defaults? | No | Yes |

## Directory Structure

Place your trinket under `charts/trinkets/`. Each trinket is a standard Helm chart with an optional `examples/` directory for testing and documentation.

```
charts/trinkets/my-trinket/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   └── my-trinket.yaml
└── examples/
    └── basic.yaml
```

For reference, here is how the existing trinkets are organized:

```
charts/trinkets/
├── microspell/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── base.yaml
│   │   ├── microservice.yaml
│   │   └── psql/
│   └── examples/
│       ├── basic-microservice.yaml
│       └── ...
└── tarot/
    ├── Chart.yaml
    ├── values.yaml
    ├── templates/
    │   ├── workflow.yaml
    │   ├── rbac.yaml
    │   ├── _helpers.tpl
    │   └── _v2.tpl
    └── examples/
        ├── v2-reusable-card.yaml
        └── ...
```

## Chart.yaml

Create a standard Helm v2 chart manifest. There are no special fields required for trinkets -- the registration happens in the book `index.yaml`, not in the chart metadata.

```yaml
# charts/trinkets/herald/Chart.yaml
apiVersion: v2
name: herald
version: 0.1.0
description: Notification system trinket for multi-channel alert delivery
home: https://github.com/your-org/herald
sources:
  - https://github.com/your-org/herald
maintainers:
  - name: your-name
    email: your-email@example.com
```

Key points:

- Set `apiVersion: v2` (Helm 3 chart format).
- The `name` field should match the directory name.
- The `version` field follows semver and is independent of the Runik Platform version.

## values.yaml

Define your trinket's default values. The Librarian passes the content of the trinket key from the spell as Helm values, so the structure of your `values.yaml` determines the API that spell authors use.

```yaml
# charts/trinkets/herald/values.yaml

# Herald configuration
herald:
  # Notification channels
  channels: {}
    # slack:
    #   webhook: ""
    #   defaultChannel: "#alerts"
    # email:
    #   smtpHost: ""
    #   smtpPort: 587
    #   from: "alerts@example.com"

  # Alert rules
  rules: {}
    # high-cpu:
    #   channel: slack
    #   severity: warning
    #   template: "CPU usage above {{ .threshold }}% on {{ .service }}"

  # Global settings
  retryPolicy:
    maxRetries: 3
    backoffSeconds: 30

  # ServiceAccount
  serviceAccount:
    enabled: true
    name: herald-notifier

# Runik Platform context (injected by Librarian)
spellbook:
  name: default
chapter:
  name: default
lexicon: {}
```

Important conventions:

- Nest your trinket's configuration under a key that matches the trinket's registered key (here, `herald`). This is the key spell authors write in their spells.
- Include `spellbook`, `chapter`, and `lexicon` stubs at the bottom. The Librarian injects these automatically so your templates can access book context, chapter context, and lexicon entries.

## Templates

Your templates receive the merged values (your defaults plus the spell's overrides plus the Librarian's context injection). You write standard Helm templates that render Kubernetes resources.

### Helper Template

```yaml
# charts/trinkets/herald/templates/_helpers.tpl
{{- define "herald.name" -}}
{{- default .Release.Name .Values.herald.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "herald.labels" -}}
app.kubernetes.io/name: {{ include "herald.name" . }}
app.kubernetes.io/managed-by: runik
runik.dev/trinket: herald
runik.dev/book: {{ .Values.spellbook.name }}
runik.dev/chapter: {{ .Values.chapter.name }}
{{- end }}
```

### Main Template

```yaml
# charts/trinkets/herald/templates/herald.yaml
{{- $root := . }}

{{- /* Render a Deployment for the notification dispatcher */}}
{{- if .Values.herald.channels }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "herald.name" . }}
  labels:
    {{- include "herald.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "herald.name" . }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "herald.name" . }}
    spec:
      {{- if .Values.herald.serviceAccount.enabled }}
      serviceAccountName: {{ .Values.herald.serviceAccount.name }}
      {{- end }}
      containers:
        - name: herald
          image: "your-org/herald:latest"
          env:
            {{- range $channelName, $channelConfig := .Values.herald.channels }}
            - name: HERALD_CHANNEL_{{ upper $channelName }}_ENABLED
              value: "true"
            {{- end }}
          volumeMounts:
            - name: config
              mountPath: /etc/herald
      volumes:
        - name: config
          configMap:
            name: {{ include "herald.name" . }}-config
{{- end }}
---
{{- /* Render a ConfigMap with channel configuration and alert rules */}}
{{- if .Values.herald.rules }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "herald.name" . }}-config
  labels:
    {{- include "herald.labels" . | nindent 4 }}
data:
  channels.yaml: |
    {{- toYaml .Values.herald.channels | nindent 4 }}
  rules.yaml: |
    {{- toYaml .Values.herald.rules | nindent 4 }}
{{- end }}
```

### Accessing Lexicon

If your trinket needs to discover infrastructure (for example, a Vault server for secret injection), you can use the lexicon the same way other charts do. The Librarian injects the full merged lexicon into your values.

```yaml
{{- /* Find a Vault server from the lexicon */}}
{{- range $name, $entry := .Values.lexicon }}
  {{- if eq $entry.type "vault" }}
    {{- /* Use $entry.server, $entry.namespace, etc. */}}
  {{- end }}
{{- end }}
```

## Register in Book index.yaml

For the Librarian to detect your trinket, you must register it in the book's `index.yaml` under the `trinkets` map. Each trinket entry has a `key` that tells the Librarian which top-level spell key triggers this trinket.

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

  herald:
    key: herald
    repository: https://github.com/your-org/herald.git
    path: .
    revision: upstream
```

### Registration Fields

| Field | Required | Description |
|-------|----------|-------------|
| `key` | Yes | The top-level YAML key in spells that triggers this trinket. When the Librarian sees this key in a spell, it adds the trinket as an ArgoCD source. |
| `repository` | Yes | Git repository URL containing the trinket chart. |
| `path` | Yes | Path to the chart directory within the repository. |
| `revision` | Yes | Git branch, tag, or commit to use. |
| `chart` | No | Use instead of `path` if the trinket is published to a Helm repository. |

### Chapter-Level Overrides

You can override trinket registration at the chapter level. For example, you might pin a specific chapter to a different revision for testing:

```yaml
# bookrack/production/applications/index.yaml
trinkets:
  herald:
    revision: feature/herald-v2
```

The Librarian merges chapter-level trinket overrides on top of book-level registrations.

## How the Trigger Mechanism Works

Understanding the Librarian's detection logic helps you design your trinket correctly.

### Step-by-Step Flow

1. **Librarian reads the book `index.yaml`** and builds a map of `trinketsByKey` from the `trinkets` block. For your herald trinket, it creates the mapping `herald -> { repository, path, revision }`.

2. **Librarian reads each spell file** in every chapter. For each spell, it checks whether any of the registered trinket keys exist as top-level keys in the spell YAML.

3. **Key detected**: When the Librarian finds `herald:` in a spell, it knows this spell needs the herald trinket.

4. **Key stripped from defaultTrinket**: The Librarian removes the `herald` key from the values passed to the primary source (summon or the defaultTrinket). This prevents summon from receiving unknown keys.

5. **Additional source added**: The Librarian adds the herald chart as an additional ArgoCD source in the generated Application. It passes the value of the `herald` key as Helm values to this source, along with the standard context (`spellbook`, `chapter`, `lexicon`, `cards`).

6. **ArgoCD syncs**: ArgoCD sees the multi-source Application and renders each source independently. The primary source (summon) renders the workload. The herald source renders the notification resources. Both are applied to the same namespace.

### What the Librarian Generates

Given a spell like this:

```yaml
# bookrack/production/applications/payment-service.yaml
name: payment-service
image: myorg/payment:v2.0

service:
  enabled: true

herald:
  channels:
    slack:
      webhook: "https://hooks.slack.com/xxx"
      defaultChannel: "#payments"
  rules:
    payment-failed:
      channel: slack
      severity: critical
      template: "Payment failed for order {{ .orderId }}"
```

The Librarian generates an ArgoCD Application with two sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
  namespace: argocd
spec:
  project: production
  sources:
    # Source 1: defaultTrinket (summon) -- workload resources
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          name: payment-service
          image: myorg/payment:v2.0
          service:
            enabled: true
          # NOTE: 'herald' key is stripped -- summon never sees it
          spellbook:
            name: production
          chapter:
            name: applications
          lexicon:
            # ... merged lexicon entries

    # Source 2: herald trinket -- notification resources
    - repoURL: https://github.com/your-org/herald.git
      path: .
      targetRevision: upstream
      helm:
        values: |
          herald:
            channels:
              slack:
                webhook: "https://hooks.slack.com/xxx"
                defaultChannel: "#payments"
            rules:
              payment-failed:
                channel: slack
                severity: critical
                template: "Payment failed for order {{ .orderId }}"
          spellbook:
            name: production
          chapter:
            name: applications
          lexicon:
            # ... merged lexicon entries
  destination:
    server: https://kubernetes.default.svc
    namespace: payment-service
```

### Key Observations

- The trinket key (`herald`) is wrapped under itself when passed to the trinket chart. Your `values.yaml` should expect values under `herald:`, not at the root level.
- The `spellbook`, `chapter`, and `lexicon` context is injected into every source, so your trinket can use book and chapter names in labels, annotations, or resource naming.
- Trinket keys are stripped from the primary source values. You do not need to worry about summon or the defaultTrinket receiving unknown keys.
- Multiple trinkets can coexist in the same spell. A spell with both `herald:` and `tarot:` produces three sources: defaultTrinket + herald + tarot.

## Example: Creating a Notification Trinket

This section walks through the complete process of creating a herald trinket for multi-channel notifications.

### Step 1: Create the Chart Structure

```bash
mkdir -p charts/trinkets/herald/templates
mkdir -p charts/trinkets/herald/examples
```

### Step 2: Write Chart.yaml

```yaml
# charts/trinkets/herald/Chart.yaml
apiVersion: v2
name: herald
version: 0.1.0
description: Multi-channel notification system for alert delivery
home: https://github.com/your-org/herald
sources:
  - https://github.com/your-org/herald
maintainers:
  - name: your-name
    email: your-email@example.com
```

### Step 3: Write values.yaml

```yaml
# charts/trinkets/herald/values.yaml
herald:
  channels: {}
  rules: {}
  retryPolicy:
    maxRetries: 3
    backoffSeconds: 30
  serviceAccount:
    enabled: true
    name: herald-notifier

spellbook:
  name: default
chapter:
  name: default
lexicon: {}
```

### Step 4: Write Templates

```yaml
# charts/trinkets/herald/templates/_helpers.tpl
{{- define "herald.name" -}}
{{- default .Release.Name .Values.herald.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "herald.fullname" -}}
{{- printf "%s-herald" (include "herald.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "herald.labels" -}}
app.kubernetes.io/name: {{ include "herald.name" . }}
app.kubernetes.io/component: notifications
app.kubernetes.io/managed-by: runik
runik.dev/trinket: herald
runik.dev/book: {{ .Values.spellbook.name }}
runik.dev/chapter: {{ .Values.chapter.name }}
{{- end }}
```

```yaml
# charts/trinkets/herald/templates/herald.yaml
{{- $root := . }}

{{- if .Values.herald.serviceAccount.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.herald.serviceAccount.name }}
  labels:
    {{- include "herald.labels" . | nindent 4 }}
---
{{- end }}

{{- if .Values.herald.channels }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "herald.fullname" . }}-config
  labels:
    {{- include "herald.labels" . | nindent 4 }}
data:
  channels.yaml: |
    {{- toYaml .Values.herald.channels | nindent 4 }}
  rules.yaml: |
    {{- toYaml .Values.herald.rules | nindent 4 }}
  retry.yaml: |
    {{- toYaml .Values.herald.retryPolicy | nindent 4 }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "herald.fullname" . }}
  labels:
    {{- include "herald.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "herald.name" . }}
      app.kubernetes.io/component: notifications
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "herald.name" . }}
        app.kubernetes.io/component: notifications
    spec:
      {{- if .Values.herald.serviceAccount.enabled }}
      serviceAccountName: {{ .Values.herald.serviceAccount.name }}
      {{- end }}
      containers:
        - name: herald
          image: "your-org/herald:latest"
          ports:
            - name: http
              containerPort: 8080
          env:
            {{- range $channelName, $channelConfig := .Values.herald.channels }}
            - name: HERALD_CHANNEL_{{ upper $channelName }}_ENABLED
              value: "true"
            {{- if $channelConfig.webhook }}
            - name: HERALD_CHANNEL_{{ upper $channelName }}_WEBHOOK
              value: {{ $channelConfig.webhook | quote }}
            {{- end }}
            {{- end }}
          volumeMounts:
            - name: config
              mountPath: /etc/herald
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: {{ include "herald.fullname" . }}-config
{{- end }}
```

### Step 5: Create an Example

```yaml
# charts/trinkets/herald/examples/basic.yaml
herald:
  channels:
    slack:
      webhook: "https://hooks.slack.com/services/T00/B00/xxx"
      defaultChannel: "#alerts"
    email:
      smtpHost: "smtp.example.com"
      smtpPort: 587
      from: "alerts@example.com"

  rules:
    high-cpu:
      channel: slack
      severity: warning
      template: "CPU usage above 90% on {{ .service }}"
    deploy-failed:
      channel: email
      severity: critical
      template: "Deployment failed for {{ .service }} in {{ .namespace }}"

  retryPolicy:
    maxRetries: 5
    backoffSeconds: 60
```

### Step 6: Register in the Book

Add the herald trinket to your book's `index.yaml`:

```yaml
# bookrack/production/index.yaml
trinkets:
  # ... existing trinkets ...
  herald:
    key: herald
    repository: https://github.com/your-org/herald.git
    path: .
    revision: upstream
```

### Step 7: Use in a Spell

Now any spell in the book can use the `herald` key to add notifications:

```yaml
# bookrack/production/applications/order-service.yaml
name: order-service
image: myorg/order-service:v1.5.0

service:
  enabled: true

herald:
  channels:
    slack:
      webhook: "https://hooks.slack.com/services/T00/B00/xxx"
      defaultChannel: "#orders"
  rules:
    order-failed:
      channel: slack
      severity: critical
      template: "Order processing failed: {{ .error }}"
```

The Librarian detects `herald:` in the spell, strips it from summon values, and adds the herald chart as a second ArgoCD source.

## Testing

### Render Locally with helm template

You can test your trinket chart in isolation using `helm template` with one of your example files:

```bash
helm template charts/trinkets/herald --values charts/trinkets/herald/examples/basic.yaml
```

This renders all templates with the example values and prints the resulting Kubernetes manifests to stdout. Inspect the output to verify that your templates produce correct resources.

### Test with Specific Values

You can pass values directly on the command line for quick iteration:

```bash
helm template charts/trinkets/herald \
  --set herald.channels.slack.webhook="https://hooks.slack.com/test" \
  --set herald.rules.test-rule.channel=slack
```

### Validate the Full Librarian Flow

To test how the Librarian integrates your trinket, render the full book:

```bash
helm template librarian/ --set name=production
```

Search the output for your trinket's source entry. You should see it as an additional source in the Application manifest for any spell that uses the `herald` key.

### Lint Your Chart

```bash
helm lint charts/trinkets/herald
```

This checks for common issues like missing required fields, invalid YAML, and template syntax errors.

## Combining Trinkets with Glyphs

Your trinket can coexist with glyphs in the same spell. The Librarian handles each independently:

```yaml
name: monitored-api
image: myorg/api:v1.0

service:
  enabled: true

# Glyph: infrastructure resources via kaster
vault:
  api-secrets:
    path: secret/data/api

istio:
  route:
    selector:
      access: external
    hosts:
      - api.example.com

# Trinket: notification system
herald:
  channels:
    slack:
      webhook: "https://hooks.slack.com/xxx"
  rules:
    api-error:
      channel: slack
      severity: critical
```

This generates an ArgoCD Application with three sources:

1. **summon** (defaultTrinket) -- Deployment, Service
2. **kaster** (glyphs) -- VaultSecret, VirtualService
3. **herald** (trinket) -- Deployment, ConfigMap for notifications

## Common Patterns

### Using defaultTrinket for Domain-Wide Conventions

If you want every spell in a chapter to use your trinket instead of summon as the primary chart, set it as the `defaultTrinket` at the chapter level:

```yaml
# bookrack/production/microservices/index.yaml
defaultTrinket:
  repository: https://github.com/runik-platform/microspell.git
  path: .
  revision: upstream
```

Now every spell in the `microservices` chapter that has an `image:` key uses microspell as its primary source instead of summon, without needing any special key.

### Trinkets That Wrap Summon

Microspell is an example of a trinket that wraps summon internally. It imports summon's templates and adds opinionated defaults on top. If you want your trinket to also render workload resources, you can follow this pattern:

```yaml
# In your Chart.yaml, no dependency is needed.
# Instead, your templates directly call summon-style templates or include
# the summon chart as a subchart dependency.
```

### Trinkets with Lexicon Integration

If your trinket needs to discover infrastructure, use the lexicon:

```yaml
# In your template
{{- range $name, $entry := .Values.lexicon }}
  {{- if eq $entry.type "smtp-server" }}
    # Use $entry.host, $entry.port, etc.
  {{- end }}
{{- end }}
```

Register the infrastructure in a spell's appendix:

```yaml
# bookrack/production/infrastructure/mail-server.yaml
name: mail-server
chart: mailhog
repository: https://codecentric.github.io/helm-charts

appendix:
  lexicon:
    mail-server:
      type: smtp-server
      host: mailhog.infrastructure.svc
      port: 1025
      labels:
        environment: production
```

Now your herald trinket can discover the mail server dynamically from any spell in the book.

## Cross-References

- [usage/trinkets.md](../usage/trinkets.md) -- User-facing Microspell and Tarot documentation, plus related Covenant invocation
- [usage/spells.md](../usage/spells.md) -- Spell types and how trinket keys trigger multi-source Applications (see Type 7)
- [usage/bookrack.md](../usage/bookrack.md) -- Book `index.yaml` trinket registration and chapter `defaultTrinket` overrides
- [design/glyphs.md](glyphs.md) -- Glyph anatomy and type system, for comparison with trinkets
- [design/creating-glyphs.md](creating-glyphs.md) -- Step-by-step guide to create a custom glyph
- [design/librarian.md](librarian.md) -- Two-pass processing, trinket detection logic, and key stripping
- [design/merge-system.md](merge-system.md) -- Cascading merge, appendix, localAppendix, defaultTrinket
- [usage/lexicon.md](../usage/lexicon.md) -- Runic Indexer and selector-based infrastructure discovery
