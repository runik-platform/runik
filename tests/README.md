# Runik test stack

Runik is an aggregate repository, so its tests validate both each renderer and
the wiring between pinned submodules. CI runs the following target. Use it
locally to reproduce the full CI run.

```bash
make ci
```

For local changes, choose a check based on the affected behavior. [Local validation guidance](../AGENTS.md#10-make-targets)

## Coverage matrix

| Gate | Coverage | Failure signal |
|---|---|---|
| `make test-glyph-name-checker` + `make check-glyph-names` | Runik's global template/chart-name checker, its positive/negative fixtures, and the selected `GLYPHS_DIR` checkout | A duplicate name, a missing checker dependency, or a checker regression |
| `make test-glyph-contracts` | Provider and legacy cert-manager contracts through both dispatchers, plus dynamic Argo Workflow naming | A cross-consumer compatibility or trigger-contract regression |
| `make test-autoscaling` | Deployment/StatefulSet replica ownership through Summon and Microspell: omitted/positive/zero replicas, HPA defaults and parameters, external mode, invalid enabled modes | Render or scaling-contract regression |
| `make test-librarian` | Librarian source contracts: Kustomize options, primary/rune/trinket isolation, empty maps, invalid definitions and unchanged complete Applications for existing sources | A renderer-selection, source-routing or compatibility regression |
| `make verify` | Recursive submodules, clean submodule worktrees, identical glyph mirror commits, fixture/snapshot inventory | Missing, uninitialized, dirty, divergent, or orphaned inputs |
| `make smoke` | Direct kaster, microspell, and Tarot examples; semantic output from every glyph example | Helm error, empty trinket output, or an untracked empty glyph render |
| `make test all` | Canonical glyphs through kaster, summon examples, and librarian books | Render error, missing snapshot, or golden diff |
| `make test integration` | Aggregate-repository Librarian bootstrap followed by real Kaster, Summon, Microspell, Tarot, and Covenant renders | Broken bootstrap, inheritance, source routing, Lexicon resolution, or child chart contract |
| `make test covenant` | Direct Covenant compilation, application-contract scanning, and deterministic alphabetical principal sharding | Broken IAM contract, cross-book scan, or nondeterministic partitioning |

`make ci-component-candidate COMPONENT=<name>` is the contract used after a
component PR commit has been checked out at its canonical Runik path. Supported
components are `glyphs`, `librarian`, `covenant`, `summon`, `kaster`, `tarot`,
and `microspell`. For Glyphs the caller installs the same candidate in every
consumer mirror. Runik verifies that all mirrors agree, checks global Glyph
names, regenerates snapshots in the disposable checkout, and executes all
aggregate render, smoke, integration, and Covenant tests.

Candidate CI intentionally skips normal top-level gitlink cleanliness checks:
the prospective commit cannot match Runik's recorded gitlink before it merges.
It still validates component-specific invariants such as the Librarian and
Covenant `bookrack` symlinks. `make ci-glyphs-candidate` remains as a
compatibility alias for `COMPONENT=glyphs`.

The Runik Makefile discovers the Glyphs and Summon examples and reads
deployable books from `tests/librarian-books.txt`. Use `make list glyphs`,
`make list examples <name>`, or `make list books` to inspect the current
inventory. `make verify` checks it against the tracked snapshots. [Makefile](../Makefile)

Librarian source-contract fixtures live in `tests/librarian/kustomize`; the
assertions are part of Runik's `make test-librarian` target. They render the
selected `LIBRARIAN_DIR` in a temporary book and compare complete Applications
with baselines from before Kustomize support. Both normal and candidate CI run
this gate. No test harness or fixtures are added to the Librarian repository.

## Book fixtures

`bookrack/example-book` is a self-contained example built from recognizable
platform operations: cert-manager and a globally published issuer, shared
PostgreSQL, Vault consuming that database service, nightly backups, web
services, IAM contracts, a Covenant deployment spell, and a
repository-bootstrap workflow. Its shapes are
reduced from real The YAML Life patterns, but it does
not read paths from a neighboring TYL checkout or carry production data.
The root `bookdeclaration.yaml` points Argo CD at `runik.git/librarian`.
Librarian reads the book through its tracked `bookrack -> ../bookrack` symlink;
the integration gate deliberately renders by release name without passing the
index as an extra values file. It then extracts each generated Argo CD
`valuesObject` and renders the corresponding local Runik component.

`bookrack/covenant-example` is the multi-file Covenant IAM book, not a
Librarian book. Its index, principals, groups, roles, bindings, realm roles,
client scopes, identity provider, and authentication flow are separate files.
A normal `infrastructure/covenant.yaml` spell inside `example-book` points to
`runik.git/covenant`; the generated Application
compiles that IAM input and scans the application contracts published by the
deployable book. `make test covenant` separately exercises compiler invariants
without Librarian.

Book roles are explicit:

- `tests/librarian-books.txt` lists deployable Librarian fixtures with goldens.
- `tests/covenant-application-books.txt` lists books Covenant scans for app IAM.
- `tests/covenant-iam-books.txt` lists IAM inputs compiled directly by Covenant.

`make verify` requires every fixture to have an explicit role, rejects IAM
inputs with Librarian chapters, rejects chapter indexes containing only a
redundant `name`, and confirms every Covenant application source is also a
deployable Librarian fixture.

## Deterministic rendering

Glyph and summon fixtures always render with Helm release `test` in namespace
`glyphs-release`. These values are explicit because `.Release.Namespace`
changes generated Vault paths and target namespaces. Local overrides are
available as `TEST_RELEASE` and `TEST_NAMESPACE`, but committed snapshots must
use the defaults.

Snapshot updates are atomic: a failed render leaves the previous golden file
untouched and returns a non-zero status.

For example, `make test glyph vault policy-role.yaml` compares that fixture
with its baseline. If its expected output changes, inspect the render and use
`make snapshot glyph vault policy-role.yaml` to update that baseline.

Review every golden diff before committing it. When a glyph example is deleted
or renamed, `make snapshot all` removes its old `.yaml.snap` after all renders
succeed. `make verify` checks for missing and orphaned snapshots across glyphs,
Summon and books.

## Empty glyph renders

Some historical glyph examples document helper or disabled paths and currently
render no Kubernetes resources through kaster. They are listed explicitly in
`tests/known-empty-fixtures.txt`. The smoke gate compares the observed empty set
with that file, preventing new empty renders from passing silently and making
the existing debt visible.

When a listed fixture starts producing a resource, remove it from the file. A
new entry should be exceptional and include an explanation in the change that
introduces it.

## Toolchain

The suite requires Bash, GNU Make, Git, Helm, diffutils, jq, ripgrep with PCRE2
support, and the Python `yq` package. Covenant relies on Python `yq` syntax
(`-y`, `-S`, and `env`) and is not compatible with the unrelated Go `yq`
binary. Its shell assertions use the portable `base64 -d` and `find -print`
forms so the same contract runs in both Debian-based Forgejo jobs and the
Alpine-based Argo PR gates.

The repository-owned Argo workflow in `.argo/tests.yaml` pins:

- Helm `3.20.2` in the Alpine/Helm test image, pinned by OCI digest.
- Python `yq` `3.4.3`.
- The Node 24 Bookworm status-reporting image by OCI digest.

## Repository workflow

`.argo/workflowConfig.yaml` selects the native test Workflow for Forgejo pushes
and pull requests. The shared discovery pipeline submits it in
`repository-workflows`; it fetches the exact `ci-sha`, verifies the checkout,
initializes every pinned submodule and runs `make ci` with a 15-minute test
timeout. Each execution uses a disposable `emptyDir` workspace.

The Workflow consumes the namespace's existing `forgejo-git-ssh` Secret
(`id_ed25519`) and `repository-workflow-known-hosts` ConfigMap
(`ssh_known_hosts`) for private recursive checkout with strict SSH host-key
verification. `forgejo-token` (`token`) is mounted only as an environment
variable in the status-reporting containers. No Forgejo Actions runner or
repository Actions secrets are needed.

The initial step reports pending; the exit handler reports success or failure,
including checkout and toolchain failures, with a link to the Argo execution.
Status contexts remain `Runik tests / test (push)` and
`Runik tests / test (pull_request)`. The namespace's default ServiceAccount
already has Argo executor permissions; the suite needs no additional RBAC,
registry credentials or Docker socket. GitHub release publication remains in
`.github/workflows/publish-release.yaml`.
