# Runik Platform

**Runik Platform** is a Kubernetes deployment framework built on Helm and ArgoCD. It provides a platform abstraction layer where developers define what they want deployed in simple YAML (spells), while platform engineers encode infrastructure patterns in reusable templates (glyphs).

A single spell like this:

```yaml
name: api-service
image: myorg/api:v1.0
vault:
  db-creds:
    path: secret/data/db
istio:
  route:
    selector:
      access: external
```

Generates an ArgoCD Application that deploys a Deployment, Service, VaultSecret, and VirtualService -- all from 8 lines of YAML.

## Quick Start

```yaml
# bookrack/production/apps/api.yaml
name: api-service
image: myorg/api:v1.0
service:
  enabled: true
```

```bash
helm template librarian/ --set name=production
```

The Librarian reads the bookrack, generates an ArgoCD Application, and ArgoCD deploys a Deployment + Service via the summon chart.

## Documentation

Repository and Argo CD source URLs are listed in
[repositories.md](repositories.md). Component examples use their standalone
GitHub repositories rather than the aggregate development checkout.

### Usage -- "I want to deploy my app"

| Document | Description |
|----------|-------------|
| [vocabulary.md](vocabulary.md) | Glossary of terms used throughout runik |
| [repositories.md](repositories.md) | GitHub repository map and deployment source rules |
| [usage/bookrack.md](usage/bookrack.md) | Books, chapters, hierarchy, and configuration merging |
| [usage/spells.md](usage/spells.md) | Spell types, anatomy, and patterns |
| [usage/summon.md](usage/summon.md) | All workload fields (Deployment, StatefulSet, Job, CronJob, DaemonSet) |
| [usage/glyphs.md](usage/glyphs.md) | Using existing glyphs (vault, istio, cert-manager, etc.) |
| [usage/lexicon.md](usage/lexicon.md) | Registering and discovering infrastructure |
| [usage/runes.md](usage/runes.md) | Adding external Helm charts as additional ArgoCD sources |
| [usage/trinkets.md](usage/trinkets.md) | Microspell and Tarot; related Covenant invocation |
| [usage/deploying.md](usage/deploying.md) | Librarian, ArgoCD, and deploy workflow |
| [usage/debugging.md](usage/debugging.md) | Troubleshooting and debug commands |
| [usage/platform-patterns.md](usage/platform-patterns.md) | Multi-env, multi-tenant, multi-cluster, security |

### Design -- "I want to understand or create my own pieces"

| Document | Description |
|----------|-------------|
| [design/architecture.md](design/architecture.md) | System overview, data flow, technology stack |
| [design/librarian.md](design/librarian.md) | Two-pass processing, detection logic, stripping, context |
| [design/summon-internals.md](design/summon-internals.md) | Template structure, workload switching, contentType system |
| [design/kaster.md](design/kaster.md) | Glyph orchestrator, dispatch logic, Go template code |
| [design/glyphs.md](design/glyphs.md) | Glyph anatomy, type system, submodule distribution |
| [design/mongodb-glyph.md](design/mongodb-glyph.md) | Percona lifecycle, generic MongoDB operations, static credentials, and scheduled backups |
| [design/trinkets.md](design/trinkets.md) | Registration, trigger mechanism, internal design |
| [design/lexicon.md](design/lexicon.md) | Runic Indexer, selection algorithm, query format |
| [design/merge-system.md](design/merge-system.md) | Cascading merge, appendix, localAppendix, defaultTrinket |
| [design/rendering-pipeline.md](design/rendering-pipeline.md) | Complete flow from spell YAML to Kubernetes resources |
| [design/creating-glyphs.md](design/creating-glyphs.md) | Step-by-step guide to create a custom glyph |
| [design/creating-trinkets.md](design/creating-trinkets.md) | Step-by-step guide to create a custom trinket |
| [design/architectural-decisions.md](design/architectural-decisions.md) | Why copy vs deps, multi-source, lexicon, two-pass |
