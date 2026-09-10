# Glyphs

Glyphs are the building blocks that generate Kubernetes-native and third-party
custom resources in Runik Platform. Each glyph is a self-contained Helm chart
whose templates produce one or more Kubernetes manifests when invoked by the
kaster orchestrator. This document covers the internal anatomy of a glyph, how
the type system dispatches to templates, naming conventions, argument passing,
and the distribution mechanism that delivers glyphs to kaster at build time.

## Anatomy of a Glyph Directory

Every glyph lives under `charts/glyphs/<chartName>/` and follows a consistent
layout:

```
charts/glyphs/vault/
├── Chart.yaml              # Glyph metadata
├── templates/
│   ├── _vault.tpl          # Main template definitions (helpers, shared logic)
│   ├── vault-secret.tpl    # vault.secret type
│   ├── vault-policy.tpl    # vault.policy type (Policy)
│   ├── vault-role.tpl      # vault.role type (KubernetesAuthEngineRole)
│   ├── vault-prolicy.tpl   # compatibility metaglyph composing policy + role
│   ├── kube-auth.tpl       # vault.kubeAuth type
│   ├── random-secret.tpl   # vault.randomSecret helper
│   ├── crypto-key.tpl      # vault.crypto-key type
│   └── ...
├── examples/               # TDD example values files
│   ├── secrets.yaml
│   ├── random-secrets.yaml
│   ├── prolicy-test.yaml
│   └── ...
└── expected-output/        # Snapshot test baselines (when present)
    └── ...
```

### Chart.yaml

The `Chart.yaml` is a standard Helm v2 chart manifest. It declares the chart
name, version, and maintainers. The `name` field is critical because it becomes
the first segment of every template name in the type system.

```yaml
apiVersion: v2
name: vault
description: vault glyph using redhat config operator
version: 1.0.0
home: https://github.com/runik-platform
sources:
  - https://github.com/runik-platform/glyphs
maintainers:
  - name: namen malkav
    email: namenmalkav@gmail.com
```

### templates/

This directory contains all Go template files. Each `.tpl` file holds one or
more `define` blocks that kaster can invoke. You split templates across files
by type -- one file per resource type, plus a shared helper file prefixed with
an underscore.

### examples/

Example values files serve as test cases for the glyph. You render them with
`helm template` during development to verify output. Each file is a
self-contained spell fragment that exercises a specific feature of the glyph.

```bash
helm template test-release charts/kaster/ -f charts/glyphs/vault/examples/secrets.yaml
```

### expected-output/

When present, this directory contains snapshot baselines for the rendered
output of the example files. CI compares `helm template` output against these
baselines to catch regressions.

## Type System

The type system is the mechanism that connects a `type:` field in a glyph
definition to a Go template `define` block. Kaster uses a single dispatcher
template that loops over all glyph definitions and calls the correct template
by constructing its name at runtime.

### How Dispatch Works

The kaster chart contains the dispatcher in
`charts/kaster/templates/kaster.yaml`:

```go
{{- $root := . }}

{{- if $root.Values.glyphs }}
  {{- range $chartName, $_ := $root.Subcharts }}
    {{- range $glyphName, $glyph := index $root.Values.glyphs $chartName }}
      {{- $glyphWithName := merge $glyph (dict "name" $glyphName) }}
      {{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
    {{- end }}
  {{- end }}
{{- end }}
```

The key line is:

```go
{{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
```

This constructs a template name from two parts:

| Part          | Source                                | Example      |
|---------------|---------------------------------------|--------------|
| `$chartName`  | Key under `glyphs:` in the spell YAML | `vault`      |
| `$glyph.type` | The `type:` field in the glyph entry  | `secret`     |

The result is a fully qualified template name like `vault.secret`,
`istio.virtualService`, or `crossplane.provider`.

### Naming Convention

The convention is `chartName.typeName` where:

- `chartName` matches the `name:` field in the glyph's `Chart.yaml`.
- `typeName` matches a `define` block inside the glyph's templates.
- Canonical chart names use lowercase kebab-case and match their directory name.

You declare the template in the `.tpl` file with a matching `define`:

```go
{{- define "vault.secret" -}}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1 }}
  ...
{{- end }}
```

### Legacy chart-name shims

> **Deprecated:** legacy chart keys are supported only as a migration aid. New
> spells must use the canonical names. See
> [Deprecations and Compatibility Window](../usage/deprecations.md) for the
> removal policy and complete alias list.

When a public glyph key is renamed, backward compatibility is implemented as a
separate library chart whose `Chart.yaml.name` is the legacy key. The shim only
defines old template names that include the canonical implementation. This lets
the unchanged kaster and summon dispatchers discover both values keys without
duplicating resource templates.

For example, `certManager.certificate` is a compatibility alias for
`cert-manager.certificate`. New spells must use `cert-manager`; existing spells
using `certManager` continue to render the same manifests.

### Type-to-Template Mapping Examples

When you write this in a spell:

```yaml
glyphs:
  vault:
    my-secret:
      type: secret
      format: env
      keys:
        - api-key
```

Kaster constructs the template name `vault.secret` and calls:

```go
{{- include "vault.secret" (list $root $glyphWithName) }}
```

Here are type mappings across several glyphs:

| Spell YAML `type:` value | Resolved template name       | File                              |
|---------------------------|------------------------------|-----------------------------------|
| `secret`                  | `vault.secret`               | `vault/templates/vault-secret.tpl`|
| `policy`                  | `vault.policy`               | `vault/templates/vault-policy.tpl`|
| `role`                    | `vault.role`                 | `vault/templates/vault-role.tpl`|
| `prolicy`                 | `vault.prolicy`              | `vault/templates/vault-prolicy.tpl` (metaglyph)|
| `kubeAuth`                | `vault.kubeAuth`             | `vault/templates/kube-auth.tpl`   |
| `virtualService`          | `istio.virtualService`       | `istio/templates/virtual-service.tpl`|
| `provider`                | `crossplane.provider`        | `crossplane/templates/provider.tpl`|
| `manifest`                | `free-form.manifest`          | `free-form/templates/free-form.tpl`|
| `eventSource`             | `argo-events.eventSource`    | `argo-events/templates/_event-source.tpl`|
| `sensor`                  | `argo-events.sensor`         | `argo-events/templates/_sensor.tpl`|
| `template`                | `workflow.template`          | `workflow/templates/_template.tpl`|
| `client`                  | `keycloak.client`            | `keycloak/templates/client.tpl`   |
| `iam-role`                | `aws.iam-role`               | `aws/templates/iam/iam-role.tpl`  |

### Glyph Name Injection

Notice that the dispatcher merges the YAML key name into the glyph definition
before calling the template:

```go
{{- $glyphWithName := merge $glyph (dict "name" $glyphName) }}
```

This means you do not need to set `name:` inside the glyph definition. The key
you use under the chart name becomes the resource name automatically:

```yaml
glyphs:
  vault:
    api-credentials:     # <-- This becomes $glyphDefinition.name
      type: secret
      format: env
      keys:
        - api-key
```

## Template Naming Conventions

Glyph templates follow a file naming pattern that makes the relationship
between files and template names predictable.

### Main Helper File

Each glyph has a main helper file prefixed with an underscore:

```
_chartName.tpl
```

Examples:
- `vault/templates/_vault.tpl` -- shared helpers like `vault.connect` and `vault.secretPath`
- `argo-events/templates/_event-source.tpl` -- the `argo-events.eventSource` template
- `argo-events/templates/_sensor.tpl` -- the `argo-events.sensor` template

The underscore prefix is a Helm convention indicating the file contains helper
templates (partials) rather than direct output. In the glyph system, some
underscore-prefixed files hold the primary `define` block for a type (as with
argo-events), while others hold shared utility definitions (as with vault).

### Type-Specific Files

Each resource type gets its own file named after the type:

```
chartName-typeName.tpl    (e.g., vault-secret.tpl)
type-name.tpl             (e.g., virtual-service.tpl, provider.tpl)
```

The choice between hyphenated and direct naming varies by glyph, but the
pattern is consistent within each glyph. The vault glyph uses the
`chartName-typeName` pattern (`vault-secret.tpl`, `vault-prolicy.tpl`). The
istio glyph uses plain type names (`virtual-service.tpl`, `gateway.tpl`). The
keycloak glyph uses plain type names (`client.tpl`, `realm.tpl`, `user.tpl`).

### Subdirectories

Some glyphs organize templates into subdirectories when they manage many
resource types. The aws glyph uses this approach:

```
aws/templates/
├── iam/
│   ├── iam-role.tpl
│   ├── iam-policy.tpl
│   ├── policybind.tpl
│   └── iam-oidc-k8s-role.tpl
├── rds/
│   ├── dbinstance-dynamic.tpl
│   ├── db-subnet-group-dynamic.tpl
│   └── db-parameter-group-dynamic.tpl
├── ack/
│   ├── ack-rds-controller.tpl
│   ├── ack-ec2-controller.tpl
│   └── ...
└── s3/
    └── bucket.tpl
```

The subdirectory structure is purely organizational. Helm flattens all `.tpl`
files regardless of directory depth, so the `define` block names remain the
same (e.g., `aws.iam-role`).

## How Glyph Templates Receive Arguments

Every glyph template receives its arguments as a Go template list with two
elements:

```go
(list $root $glyphDefinition)
```

Inside the template, you destructure the list:

```go
{{- define "vault.secret" -}}
{{- $root := index . 0 -}}
{{- $glyphDefinition := index . 1 }}
  ...
{{- end }}
```

### First Argument: Root Context

`$root` (index 0) is the full Helm root context. It gives you access to:

| Path                        | Description                                        |
|-----------------------------|----------------------------------------------------|
| `$root.Values.lexicon`      | Infrastructure definitions for runic indexer lookup |
| `$root.Values.chapter`      | Current chapter configuration (name, subdomain)     |
| `$root.Values.spellbook`    | Current book configuration (name, subdomain)        |
| `$root.Release.Namespace`   | Kubernetes namespace for the release                |
| `$root.Subcharts`           | Map of available subcharts (glyph charts)           |

Templates use `$root` to call shared helpers (`common.name`, `common.labels`)
and to query the lexicon via the runic indexer:

```go
{{- $vaultServer := get (include "runic-system.runic-indexer"
    (list $root.Values.lexicon
          (default dict $glyphDefinition.selector)
          "vault"
          $root.Values.chapter.name)
    | fromJson) "results" }}
```

### Second Argument: Glyph Definition

`$glyphDefinition` (index 1) is the specific glyph configuration from the
spell YAML, with the key name merged in as `$glyphDefinition.name`. This
object contains all the user-specified fields for that glyph entry.

For a vault secret, the definition might look like:

```yaml
type: secret
name: api-credentials    # injected by kaster dispatcher
format: env
path: chapter
keys:
  - api-key
  - api-secret
serviceAccount: my-app
```

The template accesses these fields directly:

```go
spec:
  refreshPeriod: {{ default "3m0s" $glyphDefinition.refreshPeriod }}
  output:
    name: {{ default $glyphDefinition.name $glyphDefinition.nameOverwrite }}
```

### Helper Templates with Extended Arguments

Some internal helpers accept more than two arguments. The `vault.connect`
helper, for example, takes up to five:

```go
{{- include "vault.connect" (list $root $vaultConf $forceVault $serviceAccount $customRole) }}
```

The `vault.secretPath` helper takes up to four:

```go
{{- include "vault.secretPath" (list $root $glyph $vaultConf $options) }}
```

These extended argument lists are internal to the glyph. The public contract
between kaster and every glyph template is always `(list $root $glyphDefinition)`.

## Distribution

`charts/glyphs/` is the canonical location for every glyph chart. Consumers (`charts/kaster/`, `charts/summon/`, `charts/trinkets/microspell/`, `charts/trinkets/tarot/`, `covenant/`) pick up glyphs through git submodules, each pointing at the same `glyphs.git` repository. To ship a change to a glyph, commit and push in the canonical `charts/glyphs/` submodule, then bump the submodule reference in every consumer so the new commit propagates. See the [root CLAUDE.md](../../CLAUDE.md) for the submodule layout.

## Available Glyphs

The following glyphs are currently available in the repository:

| Glyph             | Types                                                       |
|--------------------|-------------------------------------------------------------|
| `vault`           | `secret`, `policy`, `role`, `prolicy`, `kubeAuth`, `randomSecret`, `crypto-key`, `oidc-auth`, `databaseEngine`, `mongoDBEngine`, `passwd-policy`, `custom-password-policy`, `secret-engine-mount` |
| `istio`           | `virtualService`, `gateway`                                 |
| `argo-events`     | `eventSource`, `sensor`, `eventBus`                         |
| `workflow`        | `template`                                                      |
| `aws`             | `iam-role`, `iam-policy`, `policybind`, `iam-oidc-k8s-role`, `dbinstance-dynamic`, `db-subnet-group-dynamic`, `db-parameter-group-dynamic`, `ack-rds-controller`, `ack-ec2-controller`, `ack-kms-controller`, `ack-s3-controller`, `bucket` |
| `keycloak`        | `client`, `realm`, `user`, `group`, `flow`, `idp`, `clientScope`, `realmRole`, `clusterKeycloak`, `clusterRealm`, `keycloak` |
| `crossplane`      | `provider`                                                  |
| `free-form`        | `manifest`                                                  |
| `external-secrets`| AWS and GCP external secret types                           |
| `kafka`           | `cluster`, `nodePool`, `topic`, `user`, `connect`, `connector`, `mirrorMaker2`, `bridge`, `rebalance` |
| `mongodb`         | `cluster`, `engine`, `instance`, `database`, `user`, `restore` |
| `s3`              | S3-compatible bucket types                                  |
| `postgresql`      | PostgreSQL resource types                                   |
| `cert-manager`     | Certificate Manager resource types                          |
| `gcp`             | GCP infrastructure types                                    |
| `common`          | Shared helpers (`common.name`, `common.labels`, `common.secretPath`) |
| `runic-system`    | `runic-system.runic-indexer` (lexicon query engine)          |

## Cross-References

- **kaster.md** -- How the kaster dispatcher iterates over glyphs and calls templates.
- **lexicon.md** -- How the runic indexer resolves infrastructure definitions that glyphs consume via `$root.Values.lexicon`.
- **creating-glyphs.md** -- Step-by-step guide to create a new glyph from scratch.
- **rendering-pipeline.md** -- The end-to-end flow from spell YAML to rendered Kubernetes manifests, including the glyph rendering stage.
- **architectural-decisions.md** -- Rationale for the copy-based distribution model and other design choices.
- **merge-system.md** -- How values cascade from book, chapter, and spell into the context that glyphs receive.
- **trinkets.md** -- Trinkets are the sibling primitive to glyphs; understanding both gives you the full picture of runik's extensibility model.
