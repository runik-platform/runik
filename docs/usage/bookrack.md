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
image: myorg/api:v1.0
resources:
  requests:
    cpu: 100m
```

**Result after merge**:

```yaml
# Values passed to summon chart
name: api-service
image:
  repository: myorg/api
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
