# Debugging and Troubleshooting

## Quick Troubleshooting Table

| Issue | Debug Command | Fix |
|-------|---------------|-----|
| Spell not generating Application | `helm template librarian/ --set name=<book> \| grep <spell-name>` | Verify the chapter is listed in `bookrack/<book>/index.yaml` under `chapters:` |
| Glyph not rendering resources | `argocd app manifests <name> --source kaster` | Verify the glyph `type` exists as a registered template and that the trinket `kaster` is registered in `index.yaml` under `trinkets:` |
| Lexicon entry not found | `helm template librarian/ --set name=<book> --debug 2>&1 \| grep lexicon` | Check that the entry exists in the merged lexicon (book `appendix` + chapter `appendix`) and that selector labels match the entry labels |
| Values not inherited | `argocd app get <name> -o yaml` | Check the merge order (book < chapter < spell) and confirm the key is not being stripped or overridden at a later level |
| Application OutOfSync | `argocd app sync <name>` | Check for drift between the live state and the desired state; force a sync or investigate which resources diverged |

---

## Spell Not Generating an ArgoCD Application

### Example

You add a spell to `bookrack/production/applications/api-service.yaml` but after running `helm template`, no Application resource appears for `api-service`.

### Symptoms

- `helm template librarian/ --set name=production` output contains no `Application` with the expected name.
- The spell file exists in the correct directory.
- Other spells in the same book render correctly.

### Debug Steps

1. Confirm the spell file is inside a chapter directory that is listed in the book `index.yaml`:

```bash
helm template librarian/ --set name=production | grep "name: api-service"
```

If there is no output, inspect the book index:

```bash
cat bookrack/production/index.yaml
```

2. Verify the chapter appears in the `chapters:` list:

```yaml
# bookrack/production/index.yaml
chapters:
  - infrastructure
  - applications    # <-- "applications" must appear here
  - monitoring
```

3. Run the template with `--debug` to see detailed rendering information:

```bash
helm template librarian/ --set name=production --debug
```

4. Check that the spell file has a valid `.yaml` or `.yml` extension. The Librarian globs for `*.y*ml` files within each chapter directory.

5. Confirm the file is not named `index.yaml`, which is reserved for chapter configuration and is explicitly excluded from spell processing.

### Fix

Add the missing chapter name to the `chapters:` list in `bookrack/<book>/index.yaml`:

```yaml
chapters:
  - infrastructure
  - applications    # Add this line
```

If the chapter is already listed, verify the spell filename matches the glob pattern and that the YAML is syntactically valid.

---

## Glyph Not Rendering Resources

### Example

You add an `istio` block to your spell, but the rendered Application does not produce a VirtualService.

```yaml
# bookrack/production/applications/api-service.yaml
name: api-service
image: myorg/api:v1.0
service:
  enabled: true

istio:
  route:
    type: virtualService
    enabled: true
    selector:
      access: external
```

### Symptoms

- `argocd app manifests <name> --source kaster` returns no VirtualService (or no output at all).
- The Application shows only the summon source resources (Deployment, Service) but no infrastructure resources.
- ArgoCD may show the Application as Healthy even though expected resources are absent.

### Debug Steps

1. Check whether the kaster source exists on the Application:

```bash
argocd app get api-service
```

Look for a second source pointing to `./charts/kaster`. If it is missing, the Librarian did not detect a trinket key.

2. Verify the trinket registration in the book `index.yaml`. The kaster trinket must be registered with `key: glyphs`:

```yaml
# bookrack/production/index.yaml
trinkets:
  kaster:
    key: glyphs
    repository: https://github.com/runik-platform/kaster.git
    path: .
    revision: upstream
```

For summon-based spells (no `chart:` / `path:`), glyph keys like `istio:` and `vault:` sit at the top level of the spell. The Librarian does not touch those keys; they flow through to summon, where summon's own internal dispatcher iterates its subcharts and renders them inline — in the same summon source, no extra ArgoCD source emitted. The `glyphs:` wrapper + kaster source is used only when the spell's primary source is an external chart (`chart:` / `path:`).

3. Render kaster locally with the glyph values to verify the template produces resources:

```bash
helm template api-service ./charts/kaster --values <(cat <<'EOF'
glyphs:
  istio:
    route:
      type: virtualService
      enabled: true
      selector:
        access: external
spellbook:
  name: production
chapter:
  name: applications
lexicon:
  external-gateway:
    type: istio-gw
    gateway: istio-system/external-gateway
    baseURL: example.com
    labels:
      access: external
      default: book
EOF
)
```

4. Verify the glyph `type` field matches a template name in the glyph chart. For example, `type: virtualService` must match a defined template `istio.virtualService`. Check the available types:

```bash
ls charts/glyphs/istio/templates/
```

5. If you are using an external chart (spell with `chart:` and `repository:`), glyph keys must be placed inside the `glyphs:` wrapper:

```yaml
# Correct for external charts
glyphs:
  istio:
    route:
      type: virtualService
      enabled: true
```

### Fix

- Register the kaster trinket in `index.yaml` if missing.
- Verify each glyph entry has a valid `type` field that corresponds to an existing template.
- For external chart spells, wrap glyph keys inside `glyphs:`.
- Confirm the glyph has `enabled: true` if the template checks for it.

---

## Lexicon Entry Not Found

### Example

Your VirtualService glyph uses `selector: { access: external }` but no gateway is rendered because the lexicon lookup returns zero results.

```yaml
istio:
  route:
    type: virtualService
    enabled: true
    selector:
      access: external
```

### Symptoms

- Glyph templates that depend on lexicon lookups produce empty output.
- No VirtualService, no Certificate, or other resources that rely on `runicIndexer`.
- `helm template` with `--debug` shows the lexicon is empty or does not contain the expected entry.

### Debug Steps

1. Render the librarian and inspect the lexicon that gets passed to each source:

```bash
helm template librarian/ --set name=production --debug 2>&1 | grep -A 20 "lexicon:"
```

2. Check where the lexicon entry is registered. Entries come from three places, merged in order:

| Source | Location | Scope |
|--------|----------|-------|
| Book `appendix.lexicon` | `bookrack/<book>/index.yaml` | All spells in the book |
| Chapter `appendix.lexicon` | `bookrack/<book>/<chapter>/index.yaml` | All spells in the book (merged into global) |
| Spell `appendix.lexicon` | `bookrack/<book>/<chapter>/<spell>.yaml` | All spells in the book (merged into global) |
| Chapter `localAppendix.lexicon` | `bookrack/<book>/<chapter>/index.yaml` | Only spells in that chapter |
| Spell `localAppendix.lexicon` | `bookrack/<book>/<chapter>/<spell>.yaml` | Only that spell |

3. Verify label matching. The `runicIndexer` uses AND logic -- all selector labels must match:

```yaml
# Lexicon entry
external-gateway:
  type: istio-gw
  labels:
    access: external       # Must match
    environment: production  # Must also match if selected
    default: book

# Selector in glyph
selector:
  access: external         # Matches
  environment: staging     # Does NOT match -> no result
```

4. Understand the fallback logic. If no exact selector match is found, the indexer falls back to:
   - A lexicon entry with `labels.default: book` (book-wide default)
   - A lexicon entry with `labels.default: chapter` in the same chapter

5. Test the lexicon merge locally:

```bash
helm template test-kaster ./charts/kaster --values <(cat <<'EOF'
glyphs:
  istio:
    route:
      type: virtualService
      enabled: true
      selector:
        access: external
lexicon:
  external-gateway:
    name: external-gateway
    type: istio-gw
    gateway: istio-system/external-gateway
    baseURL: example.com
    labels:
      access: external
      default: book
EOF
)
```

### Fix

- Add the missing lexicon entry to the appropriate `appendix.lexicon` in the book, chapter, or spell.
- Ensure the `type` field in the lexicon entry matches what the glyph template queries (e.g., `istio-gw` for VirtualService, `vault` for VaultSecret).
- Ensure all labels in the selector exist and match exactly in the lexicon entry.

---

## Values Not Inherited

### Example

You set `namePrefix: prod-` in the book `index.yaml`, but spells do not use the prefix.

### Symptoms

- A value you defined at the book level does not appear in the rendered Application.
- Chapter-level overrides are not taking effect.
- The merge order seems incorrect.

### Debug Steps

1. Inspect the rendered Application to see the actual values being passed:

```bash
argocd app get api-service -o yaml
```

Look at `spec.sources[].helm.values` to see the merged values that reach each chart source.

2. Alternatively, inspect the Application directly with kubectl:

```bash
kubectl get application api-service -n argocd -o yaml
```

3. Render the librarian locally to inspect the full output:

```bash
helm template librarian/ --set name=production --debug
```

4. Check the merge order. Runik Platform merges values as:

```
Book (index.yaml)  <  Chapter (chapter/index.yaml)  <  Spell (spell.yaml)
```

Later levels override earlier ones. If the same key appears at both the book and spell level, the spell value wins.

5. Some keys are explicitly stripped before being passed to chart sources. The following keys are removed from summon values:

| Key | Reason |
|-----|--------|
| `runes` | Processed separately as additional sources |
| `appParams` | Used for Application metadata, not chart values |
| `appendix` | Collected into the global appendix, not passed as values |
| `localAppendix` | Collected into local scope, not passed as values |
| All trinket keys (e.g., `glyphs`) | Passed to the trinket source, stripped from defaultTrinket |

6. Check for `localAppendix` vs `appendix` confusion:

```yaml
# This is visible to ALL spells in the book
appendix:
  lexicon:
    my-gateway: { ... }

# This is visible ONLY to spells in this chapter
localAppendix:
  lexicon:
    my-gateway: { ... }
```

### Fix

- Ensure the key you are trying to inherit is not in the stripped list.
- Use `appendix` (not `localAppendix`) if the value should be visible book-wide.
- If a chapter or spell is overriding the value, check whether `mergeOverwrite` behavior (deep merge, later wins) is producing unexpected results.
- Use `helm template librarian/ --set name=<book> --debug` to trace the exact values at each level.

---

## Application OutOfSync

### Example

ArgoCD shows an Application as `OutOfSync` even though you have not changed any spell files.

### Symptoms

- The ArgoCD dashboard shows a yellow `OutOfSync` status.
- `argocd app get <name>` reports resources that differ between live and desired state.
- The Application may have been modified directly in the cluster (manual kubectl edits, operators mutating resources, etc.).

### Debug Steps

1. Check which resources are out of sync:

```bash
argocd app get api-service
```

2. View the specific resource differences:

```bash
argocd app resources api-service
```

3. View the desired manifests to compare with live state:

```bash
argocd app manifests api-service
```

4. Describe the Application for events and conditions:

```bash
kubectl describe application api-service -n argocd
```

5. Check the live resources in the target namespace:

```bash
kubectl get deployment,pods,svc,virtualservice -n applications
```

For VaultSecret resources:

```bash
kubectl get vaultsecret -n applications
```

6. If the drift is caused by a mutating webhook or operator (e.g., Istio sidecar injection adding annotations), configure `ignoreDifferences` in the spell:

```yaml
appParams:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/metadata/annotations
```

### Fix

- To reconcile the live state with the desired state, sync the application:

```bash
argocd app sync api-service
```

- If drift is expected (operator-managed fields), add `ignoreDifferences` to the spell `appParams`.
- If auto-sync is disabled and you want to re-enable it, remove `disableAutoSync: true` from the spell or chapter.
- Investigate whether a manual `kubectl edit` or `kubectl apply` has modified cluster resources outside of ArgoCD.

---

## Debug Commands Reference

### Librarian (Application Generation)

| Command | Purpose |
|---------|---------|
| `helm template librarian/ --set name=<book>` | Render all Applications for a book |
| `helm template librarian/ --set name=<book> --debug` | Render with verbose debug output showing merge steps |
| `helm template librarian/ --set name=<book> \| grep <spell>` | Check if a specific spell generates an Application |

### ArgoCD (Application State)

| Command | Purpose |
|---------|---------|
| `argocd app get <name>` | Show Application status, health, sync state, and sources |
| `argocd app get <name> -o yaml` | Full Application spec as YAML including merged values |
| `argocd app resources <name>` | List all managed resources with their sync and health status |
| `argocd app manifests <name>` | Show the desired manifests ArgoCD would apply |
| `argocd app manifests <name> --source kaster` | Show only the manifests from the kaster source |
| `argocd app sync <name>` | Trigger a sync to reconcile live state with desired state |

### Kubernetes (Live Resources)

| Command | Purpose |
|---------|---------|
| `kubectl get application <name> -n argocd -o yaml` | Inspect the raw Application CR in the cluster |
| `kubectl describe application <name> -n argocd` | Show Application events, conditions, and status details |
| `kubectl get deployment -n <namespace>` | List deployments in the target namespace |
| `kubectl get pods -n <namespace>` | List pods in the target namespace |
| `kubectl get svc -n <namespace>` | List services in the target namespace |
| `kubectl get vaultsecret -n <namespace>` | List VaultSecret resources |
| `kubectl get virtualservice -n <namespace>` | List Istio VirtualService resources |

### Chart Rendering (Local Debugging)

| Command | Purpose |
|---------|---------|
| `helm template <name> ./charts/summon --values <values-file>` | Render summon chart locally with custom values |
| `helm template <name> ./charts/kaster --values <values-file>` | Render kaster chart locally with glyph values |
| `helm template <name> ./charts/trinkets/tarot --values <values-file>` | Render tarot trinket locally |
| `helm template <name> ./charts/trinkets/microspell --values <values-file>` | Render microspell trinket locally |

### Workflow: End-to-End Debugging

When you encounter an issue, follow this sequence:

```bash
# 1. Does the spell generate an Application?
helm template librarian/ --set name=production | grep "name: api-service"

# 2. What does the full rendered Application look like?
helm template librarian/ --set name=production --debug

# 3. What is ArgoCD's view of the Application?
argocd app get api-service
argocd app resources api-service

# 4. What manifests does ArgoCD want to apply?
argocd app manifests api-service

# 5. What is actually running in the cluster?
kubectl get deployment,pods,svc -n applications

# 6. Render individual charts to isolate the problem
helm template api-service ./charts/summon --values extracted-values.yaml
helm template api-service ./charts/kaster --values extracted-glyph-values.yaml
```

---

## Cross-References

- [spells.md](spells.md) -- Spell types, anatomy, and detection logic
- [bookrack.md](bookrack.md) -- Book and chapter structure, configuration merging
- [deploying.md](deploying.md) -- Librarian processing, ArgoCD integration
- [glyphs.md](glyphs.md) -- Available glyph types and their configuration
- [lexicon.md](lexicon.md) -- Lexicon registration, runicIndexer selection algorithm
- [trinkets.md](trinkets.md) -- Trinket registration (kaster, tarot, microspell)
- [summon.md](summon.md) -- Workload configuration fields
