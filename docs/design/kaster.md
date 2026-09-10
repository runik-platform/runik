# Kaster -- Glyph Orchestrator

Kaster is the orchestration chart that dispatches glyph definitions to their
corresponding glyph templates. It receives infrastructure declarations from the
Librarian (vault secrets, Istio routes, cert-manager certificates, and so on)
and invokes the correct glyph template for each one, producing the final
Kubernetes resource YAML.

You can think of kaster as a router: it does not know what a VaultSecret or a
VirtualService looks like, but it knows how to find the glyph template that does
and how to call it with the right context.

**Location**: `charts/kaster/`

## How Kaster Receives Data

When the Librarian processes a spell that contains glyph keys (`vault:`,
`istio:`, `cert-manager:`, etc.), it generates an ArgoCD Application with
kaster as an additional source. The Librarian passes three categories of data
to kaster through Helm values:

```yaml
# Values kaster receives at render time
glyphs:
  vault:
    db-creds:
      type: secret
      path: chapter
      keys: [username, password]
  istio:
    route:
      type: virtualService
      enabled: true
      selector:
        access: external

spellbook:
  name: my-book
chapter:
  name: production

lexicon:
  vault-server:
    type: vault
    address: https://vault.internal:8200
    labels:
      default: book
  external-gateway:
    type: istio-gw
    gateway: infrastructure/external-gateway
    baseURL: example.com
    labels:
      access: external
```

- **glyphs** -- the infrastructure definitions, grouped by subchart name.
- **spellbook / chapter** -- book context inherited from the Librarian.
- **lexicon** -- the infrastructure registry for Runic Indexer queries.

## Template Logic

The entire kaster template lives in a single file,
`charts/kaster/templates/kaster.yaml`. Here is the complete dispatch logic:

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

Walk through each line to understand the dispatch:

### Step 1 -- Guard on glyphs

```go
{{- if $root.Values.glyphs }}
```

If the values contain no `glyphs` key at all, kaster produces no output. This
makes it safe to include kaster as a source even when no infrastructure
resources are needed.

### Step 2 -- Iterate over registered subcharts

```go
{{- range $chartName, $_ := $root.Subcharts }}
```

`$root.Subcharts` is a built-in Helm map that contains every subchart
registered under `charts/kaster/charts/`. These subcharts are glyph libraries
(vault, istio, cert-manager, keycloak, aws, crossplane, etc.) that live in
`charts/kaster/charts/` through a git submodule of `glyphs.git`. The variable
`$_` is discarded because you only need the subchart name as the dispatch key.

### Step 3 -- Iterate over glyph definitions for that subchart

```go
{{- range $glyphName, $glyph := index $root.Values.glyphs $chartName }}
```

For each subchart name (e.g. `vault`), this looks up
`$root.Values.glyphs.vault` and iterates over every glyph definition under it.
Each definition has a user-provided name (`$glyphName`, such as `db-creds`) and
a configuration map (`$glyph`) that includes at minimum a `type` field.

### Step 4 -- Inject the name and dispatch

```go
{{- $glyphWithName := merge $glyph (dict "name" $glyphName) }}
{{- include (printf "%s.%s" $chartName $glyph.type) (list $root $glyphWithName) }}
```

The glyph name from the map key is merged into the definition as the `name`
field, so glyph templates can reference `$glyphDefinition.name` without the
caller having to repeat it.

The `include` call constructs the template name dynamically by combining the
subchart name and the glyph type. For example, if `$chartName` is `vault` and
`$glyph.type` is `secret`, it calls the template named `vault.secret`. The
template receives a two-element list: the full chart root context and the glyph
definition.

## Subchart Registration

For the dispatch to work, each glyph must be present as a Helm subchart inside
`charts/kaster/charts/`. Glyphs are authored canonically in `charts/glyphs/`;
`charts/kaster/charts/` is a git submodule tracking the same `glyphs.git`
repository, so Helm sees every glyph as a subchart under kaster.

The directory structure looks like this:

```
charts/kaster/
  Chart.yaml
  values.yaml
  templates/
    kaster.yaml         # The dispatch template
  charts/               # submodule of glyphs.git
    vault/
      templates/
        vault-secret.tpl
        vault-prolicy.tpl
        ...
    istio/
      templates/
        virtual-service.tpl
        gateway.tpl
    cert-manager/
    keycloak/
    aws/
    crossplane/
    ...
```

Helm populates `$root.Subcharts` with a key for each directory under
`charts/kaster/charts/`. That is the only reason the `range $chartName` loop
works -- if the kaster submodule has not been bumped to a commit that contains
a given glyph, kaster cannot dispatch to it.

## How Context Is Passed

Every glyph template receives the same two-element list:

```go
(list $root $glyphWithName)
```

- **$root** (`index . 0`) -- the full Helm chart root. This gives the glyph
  template access to `$root.Values.lexicon`, `$root.Values.spellbook`,
  `$root.Values.chapter`, and `$root.Release`. Glyph templates use the lexicon
  to perform Runic Indexer queries (e.g., find the Vault server or Istio
  gateway that matches a selector).

- **$glyphWithName** (`index . 1`) -- the glyph definition with `name`
  injected. Contains `type`, user-specified fields, and optionally a `selector`
  for Runic Indexer lookups.

Inside a glyph template, the pattern always starts like this:

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
...
{{- end }}
```

The lexicon from `$root.Values.lexicon` is available to all glyph templates
without any extra wiring. The Librarian assembles the lexicon from the
appendix system and passes it to kaster as a Helm value.

## Separation of Concerns -- Summon vs Kaster

Runik deliberately separates workload resources from infrastructure resources
into two independent ArgoCD sources:

| Concern | Chart | Resources |
|---------|-------|-----------|
| Workload | summon | Deployment, Service, ServiceAccount, ConfigMap, Secret, PV/PVC, StatefulSet, Job, CronJob, DaemonSet |
| Infrastructure | kaster | VaultSecret, VirtualService, Gateway, Certificate, KeycloakRealm, IAM roles, Crossplane providers, etc. |

Both are sources within the same ArgoCD Application, but they render
independently:

```yaml
# ArgoCD Application generated by the Librarian
spec:
  sources:
    - repoURL: https://github.com/runik-platform/summon.git
      path: .
      helm:
        values: |
          name: api-service
          image: myorg/api:v1.0
          service:
            enabled: true
          # ... workload fields only, glyph keys stripped

    - repoURL: https://github.com/runik-platform/kaster.git
      path: .
      helm:
        values: |
          glyphs:
            vault:
              db-creds:
                type: secret
                path: chapter
                keys: [username, password]
            istio:
              route:
                type: virtualService
                enabled: true
                selector:
                  access: external
          spellbook:
            name: my-book
          chapter:
            name: production
          lexicon:
            vault-server: { ... }
            external-gateway: { ... }
```

This separation means:

- Summon never sees glyph keys. The Librarian strips them before passing values
  to summon.
- Kaster receives only the `glyphs` block from the spell plus the injected
  context: `spellbook`, `chapter`, and `lexicon`. Nothing else from the spell
  reaches kaster.
- Each chart can evolve independently. You can add new glyph types without
  touching summon, and vice versa.
- ArgoCD can diff and sync each source independently.

## Why Glyphs Are Tested Only via Kaster

Glyphs are Helm template libraries. They consist entirely of `define` blocks
(files named `_*.tpl` or `*.tpl`) and produce no output on their own. A glyph
chart has no standalone templates -- if you run `helm template` directly on
`charts/glyphs/vault/`, you get nothing.

Glyphs require kaster's orchestration context to render:

1. **$root.Subcharts** must contain the glyph as a registered subchart.
2. **$root.Values.glyphs** must contain definitions that reference the glyph's
   types.
3. **$root.Values.lexicon** must contain infrastructure entries for Runic
   Indexer queries.
4. The dispatch loop in `kaster.yaml` must call the glyph template with the
   correct `(list $root $glyphDefinition)` signature.

To test a glyph, you create an example values file (see
`charts/kaster/examples/`) and render it through kaster:

```bash
# Test vault glyph through kaster
helm template kaster charts/kaster/ \
  -f charts/kaster/examples/my-vault-test.yaml

# The make target automates this pattern
make glyphs vault
```

The `make glyphs <name>` target runs `helm template` against kaster with the
appropriate test values for the named glyph. This is the canonical way to
develop and validate glyphs.

## Worked Example

Consider a spell that declares a Vault secret and an Istio virtual service:

### Input -- spell values passed to kaster

```yaml
spellbook:
  name: my-book
chapter:
  name: production

lexicon:
  vault-prod:
    name: vault-prod
    type: vault
    address: https://vault.internal:8200
    authPath: kubernetes
    secretPath: secret
    labels:
      default: book
  external-gw:
    name: external-gw
    type: istio-gw
    gateway: infrastructure/external-gateway
    baseURL: example.com
    labels:
      access: external

glyphs:
  vault:
    db-creds:
      type: secret
      format: env
      path: chapter
      keys:
        - username
        - password
  istio:
    api-route:
      type: virtualService
      enabled: true
      selector:
        access: external
```

### Dispatch sequence

1. Kaster iterates `$root.Subcharts`. It finds `vault` and `istio` (among
   others).

2. For `vault`, it looks up `$root.Values.glyphs.vault` and finds one entry:
   `db-creds`. It merges `name: db-creds` into the definition and calls:

   ```go
   {{- include "vault.secret" (list $root $glyphWithName) }}
   ```

3. The `vault.secret` template queries the Runic Indexer with
   `$root.Values.lexicon`, selector `{}` (no selector specified), type
   `"vault"`, and chapter `"production"`. It finds `vault-prod` and uses its
   `secretPath` and `authPath` to generate the VaultSecret resource.

4. For `istio`, kaster finds one entry: `api-route`. It merges
   `name: api-route` into the definition and calls:

   ```go
   {{- include "istio.virtualService" (list $root $glyphWithName) }}
   ```

5. The `istio.virtualService` template queries the Runic Indexer with
   selector `{access: external}`, type `"istio-gw"`, and chapter
   `"production"`. It finds `external-gw` and uses its `gateway` and
   `baseURL` to generate the VirtualService resource.

### Output -- rendered Kubernetes resources

```yaml
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: VaultSecret
metadata:
  name: db-creds
  labels:
    app.kubernetes.io/managed-by: Helm
spec:
  refreshPeriod: 3m0s
  vaultSecretDefinitions:
    - name: secret
      requestType: GET
      path: secret/data/my-book/production/publics/db-creds
      authentication:
        path: kubernetes
        role: ...
        serviceAccount:
          name: default
  output:
    name: db-creds
    stringData:
      USERNAME: '{{ .secret.username }}'
      PASSWORD: '{{ .secret.password }}'
    type: Opaque
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-route-external-gw
spec:
  hosts:
    - example.com
  gateways:
    - infrastructure/external-gateway
  http:
    - match:
        - uri:
            prefix: /api-route
      rewrite:
        uri: /
      route:
        - destination:
            host: api-route.production.svc.cluster.local
            port:
              number: 80
```

Two glyph definitions in, two Kubernetes resources out. Kaster itself produced
zero lines of resource YAML -- it only dispatched.

## Cross-References

- **[glyphs.md](glyphs.md)** -- Glyph anatomy, type system, and submodule
  distribution.
- **[lexicon.md](lexicon.md)** -- Runic Indexer query format and selection
  algorithm.
- **[librarian.md](librarian.md)** -- How the Librarian detects glyph keys,
  strips them from summon, and passes them to kaster.
- **[summon-internals.md](summon-internals.md)** -- The workload chart that
  handles the other side of the separation.
- **[rendering-pipeline.md](rendering-pipeline.md)** -- End-to-end flow from
  spell YAML to Kubernetes resources.
- **[creating-glyphs.md](creating-glyphs.md)** -- Step-by-step guide to
  building a custom glyph.
- **[architectural-decisions.md](architectural-decisions.md)** -- Why copy vs
  deps, multi-source, and the two-chart split.
