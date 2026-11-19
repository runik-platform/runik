# Bookrack, Books, and Chapters

## What is a Bookrack?

The `bookrack/` directory is the root of all configuration. It contains books, which contain chapters, which contain spells.

```
bookrack/                          <- The bookrack (root)
├── production/                    <- Book (environment/tenant)
│   ├── index.yaml                 <- Book configuration
│   ├── infrastructure/            <- Chapter (logical grouping)
│   │   ├── gateway.yaml           <- Spell (individual resource)
│   │   └── vault.yaml
│   ├── applications/              <- Chapter
│   │   ├── api-service.yaml
│   │   └── frontend.yaml
│   └── databases/                 <- Chapter
│       └── postgres.yaml
├── staging/                       <- Another book
│   ├── index.yaml
│   └── ...
└── development/                   <- Another book
    ├── index.yaml
    └── ...
```

## Create a book in your own repository

Start in the root of your content repository. The example uses `my-book` for the book directory, index name, and Helm release. Your repository can have any name.

```text
.
├── .gitmodules
├── bookdeclaration.yaml
├── bookrack/my-book/
│   ├── index.yaml
│   └── apps/web.yaml
└── librarian/                  # Git submodule
    └── bookrack -> ../bookrack
```

### Add Librarian from GitHub

Initialize the content repository and add the public Librarian chart. For an existing Git repository, start at `git submodule add`. This example pins the published `v1.2.7` releases of Librarian and Summon.

```bash
git init
git submodule add https://github.com/runik-platform/librarian.git librarian
git -C librarian checkout --detach v1.2.7
git add librarian
mkdir -p bookrack/my-book/apps
```

The resulting `.gitmodules` entry records the public clone URL.

```ini
[submodule "librarian"]
    path = librarian
    url = https://github.com/runik-platform/librarian.git
```

The submodule already tracks the `bookrack -> ../bookrack` symlink. It lets Helm read your book from inside the chart. On a fresh clone of the content repository, `git submodule update --init --recursive` restores the recorded commit.

### Declare the book and its first spell

Save the book index as `bookrack/my-book/index.yaml`. Librarian reads the chapters listed here. The `defaultTrinket` selects Summon for spells without a `chart` or `path` of their own.

```yaml
name: my-book
chapters: [apps]
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: v1.2.7
```

Save the workload as `bookrack/my-book/apps/web.yaml`.

```yaml
name: web
namespace: my-book
image:
  repository: docker.io/library
  name: nginx
  tag: stable-alpine
```

### Render the book and workload locally

Render the book from the root of the content repository.

```bash
helm template my-book ./librarian --namespace argocd
```

Look for `kind: Application` with `metadata.name: web` in the output. Its Summon source is at `v1.2.7` and its destination namespace is `my-book`. The Helm release name `my-book` selects `bookrack/my-book/index.yaml`.

To see the Kubernetes resources before deploying, use `yq` to extract that Application and its Helm values. Clone the Git source at the tag emitted by Librarian, including Summon's submodules.

```bash
render_dir=$(mktemp -d)
helm template my-book ./librarian --namespace argocd |
  yq -e 'select(.kind == "Application" and .metadata.name == "web")' > "$render_dir/web.yaml"
summon_repo=$(yq -r '.spec.sources[0].repoURL' "$render_dir/web.yaml")
summon_tag=$(yq -r '.spec.sources[0].targetRevision' "$render_dir/web.yaml")
git clone --quiet --recurse-submodules --branch "$summon_tag" "$summon_repo" "$render_dir/summon"
yq '.spec.sources[0].helm.valuesObject' "$render_dir/web.yaml" |
  helm template web "$render_dir/summon" --namespace my-book --values -
```

The second render uses the child Application's release name (`web`) and destination namespace (`my-book`). It produces a Deployment, Service, and ServiceAccount named `web`. Both renders run locally without a Kubernetes cluster.

### Bootstrap the book in Argo CD

Save the parent Application as `bookdeclaration.yaml` at the content repository root. Replace the two placeholders with the clone URL and published branch, tag, or commit of **your content repository**. Argo CD checks out that revision and runs Helm at `path: librarian` with `my-book` as the release name.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-book
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <content-repository-url>
    targetRevision: <content-revision>
    path: librarian
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
```

Commit `.gitmodules`, the `librarian` submodule pointer, `bookrack/`, and `bookdeclaration.yaml` in the content repository. Publish the revision, then register and sync the parent Application through your Argo CD bootstrap process. Argo CD needs read access to the content repository and its submodule sources.

## Books

A **book** represents a complete environment or tenant. Examples: `production`, `staging`, `customer-acme`, `us-west`.

Every book has an `index.yaml` that configures how spells in that book are processed.

### Book index.yaml -- All Fields

```yaml
name: production

# Ordered list of chapters -- defines deployment order
chapters:
  - infrastructure    # Deploy first
  - applications      # Deploy second
  - monitoring        # Deploy third

# Chart used for spells with image: (typically summon)
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream

# Specialized charts triggered by keys in spells
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

# Shared configuration inherited by all chapters and spells
appendix:
  lexicon:
    production-vault:
      type: vault
      url: https://vault.production.svc
      namespace: vault
      labels:
        environment: production
        default: book

# Name prefix/suffix applied to all spells
namePrefix: ""
nameSuffix: ""
```

**Key fields**:

| Field | Purpose |
|-------|---------|
| `chapters` | Ordered list of chapter directories |
| `defaultTrinket` | Chart for `image:` spells (summon) |
| `trinkets` | Specialized charts triggered by spell keys |
| `appendix` | Shared lexicon entries for the entire book |
| `namePrefix`/`nameSuffix` | Applied to all resource names |

## Chapters

A **chapter** is a directory inside a book that groups related spells. Common chapters: `infrastructure`, `applications`, `databases`, `monitoring`, `batch-jobs`.

### Chapter index.yaml (Optional)

Chapters can optionally have an `index.yaml` to override book-level settings.

```yaml
name: applications

# Override defaultTrinket for this chapter
defaultTrinket:
  repository: https://github.com/runik-platform/microspell.git
  path: .
  revision: upstream

# Chapter-specific appendix (merged with book appendix)
appendix:
  lexicon:
    app-database:
      type: database
      host: postgres-rw.databases.svc
      port: 5432

# Chapter-only overrides (NOT inherited by other chapters)
localAppendix:
  lexicon:
    external-gateway:
      baseURL: apps.example.com
```

**Key differences between appendix and localAppendix**:

| | `appendix` | `localAppendix` |
|-|-----------|-----------------|
| Scope | Merged into global appendix (visible to all spells in book) | Only visible to spells in this chapter |
| Use case | Register infrastructure for the whole book | Override a lexicon entry for one chapter |

## Configuration Merging

Runik Platform uses a cascading merge where later levels override earlier ones:

```
Book (index.yaml)  <  Chapter (chapter/index.yaml)  <  Spell (spell.yaml)
```

### Merge Example

**Book** (`production/index.yaml`):
```yaml
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: upstream

appendix:
  lexicon:
    vault:
      url: https://vault.production.svc
      namespace: vault
      labels:
        environment: production
```

**Chapter** (`production/apps/index.yaml`):
```yaml
defaultTrinket:
  revision: <published-summon-tag-or-commit>  # Overrides book's revision

appendix:
  lexicon:
    database:
      host: postgres.apps.svc
      port: 5432
```

**Spell** (`production/apps/api-service.yaml`):
```yaml
name: api-service
image:
  repository: myorg
  name: api
  tag: v1.0
resources:
  requests:
    cpu: 100m
```

**Result after merge**:

```yaml
# Values passed to summon chart
name: api-service
image:
  repository: myorg
  name: api
  tag: v1.0
resources:
  requests:
    cpu: 100m

# Context from book/chapter
spellbook:
  name: production
chapter:
  name: apps

# Merged lexicon (book + chapter)
lexicon:
  vault:
    url: https://vault.production.svc
    namespace: vault
    labels:
      environment: production
  database:
    host: postgres.apps.svc
    port: 5432
```

The spell inherits the vault lexicon from the book and the database lexicon from the chapter. The defaultTrinket uses the published Summon tag or commit from the chapter override.

## Chapter Ordering

Chapters are processed in the order defined in `index.yaml`:

```yaml
chapters:
  - 00-namespaces       # Create namespaces first
  - 01-infrastructure   # Deploy Istio, Vault, etc.
  - 02-databases        # Deploy databases
  - 03-applications     # Deploy apps (depend on infra)
  - 04-monitoring       # Deploy monitoring last
```

For fine-grained ordering within a chapter, use ArgoCD sync waves:

```yaml
# In spell
appParams:
  annotations:
    argocd.argoproj.io/sync-wave: "10"
```

## Common Organization Patterns

### Single Environment

```
bookrack/
└── production/
    ├── index.yaml
    ├── infrastructure/
    └── apps/
```

### Multi-Environment

```
bookrack/
├── production/
├── staging/
└── development/
```

### Multi-Tenant

```
bookrack/
├── tenant-acme/
├── tenant-globex/
└── tenant-initech/
```

### Regional

```
bookrack/
├── us-west/
├── us-east/
├── eu-central/
└── ap-southeast/
```

## Multi-Environment Example

```
bookrack/
├── production/
│   ├── index.yaml
│   │   appendix:
│   │     lexicon:
│   │       vault: { url: vault.prod.svc, labels: { default: book } }
│   ├── infrastructure/
│   │   └── external-gateway.yaml
│   │       appendix:
│   │         lexicon:
│   │           external-gateway:
│   │             type: istio-gw
│   │             labels: { access: external, default: book }
│   └── applications/
│       ├── api-service.yaml      # Same spell in both envs
│       └── frontend.yaml
│
├── staging/
│   ├── index.yaml
│   │   appendix:
│   │     lexicon:
│   │       vault: { url: vault.staging.svc, labels: { default: book } }
│   └── applications/
│       ├── api-service.yaml      # Identical spell -- different env via lexicon
│       └── frontend.yaml
```

The same spell works in both environments because infrastructure is discovered dynamically via the lexicon. See [lexicon.md](lexicon.md) for details.

## Cross-References

- [spells.md](spells.md) -- What goes inside each spell YAML file
- [lexicon.md](lexicon.md) -- How appendix.lexicon entries enable dynamic discovery
- [deploying.md](deploying.md) -- How the Librarian processes the bookrack
- [design/merge-system.md](../design/merge-system.md) -- Internal merge implementation
