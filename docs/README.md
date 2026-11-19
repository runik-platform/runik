# Runik Platform

**Runik Platform** is a Kubernetes deployment framework built on Helm and ArgoCD. It provides a platform abstraction layer where developers define what they want deployed in simple YAML (spells), while platform engineers encode infrastructure patterns in reusable templates (glyphs).

Librarian reads a book and generates an Argo CD Application for each spell. Summon renders the workload. A spell can also use glyphs to declare resources such as Vault secrets and Istio routes.

## Quick Start

From an empty directory, initialize the content repository, install Librarian from GitHub at a published tag, and create the `apps` chapter.

```bash
git init
git submodule add https://github.com/runik-platform/librarian.git librarian
git -C librarian checkout --detach v1.2.7
git add librarian
mkdir -p bookrack/my-book/apps
```

Save the index and spell at the paths shown. The index activates the `apps` chapter and selects the Summon revision.

```yaml
# bookrack/my-book/index.yaml
name: my-book
chapters: [apps]
defaultTrinket:
  repository: https://github.com/runik-platform/summon.git
  path: .
  revision: v1.2.7
```

```yaml
# bookrack/my-book/apps/web.yaml
name: web
namespace: my-book
image:
  repository: docker.io/library
  name: nginx
  tag: stable-alpine
```

Use the book name as the Helm release when rendering from the repository root.

```bash
helm template my-book ./librarian --namespace argocd
```

Look for `Application/web` in the output. It points to Summon and targets the `my-book` namespace. Continue with [the local workload render](usage/bookrack.md#render-the-book-and-workload-locally) or [the Argo CD bootstrap](usage/bookrack.md#bootstrap-the-book-in-argo-cd).

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
| [design/trinkets.md](design/trinkets.md) | Registration, trigger mechanism, internal design |
| [design/lexicon.md](design/lexicon.md) | Runic Indexer, selection algorithm, query format |
| [design/merge-system.md](design/merge-system.md) | Cascading merge, appendix, localAppendix, defaultTrinket |
| [design/rendering-pipeline.md](design/rendering-pipeline.md) | Complete flow from spell YAML to Kubernetes resources |
| [design/creating-glyphs.md](design/creating-glyphs.md) | Step-by-step guide to create a custom glyph |
| [design/creating-trinkets.md](design/creating-trinkets.md) | Step-by-step guide to create a custom trinket |
| [design/architectural-decisions.md](design/architectural-decisions.md) | Why copy vs deps, multi-source, lexicon, two-pass |
