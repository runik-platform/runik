# Runik test stack

Runik is an aggregate repository, so its tests validate both each renderer and
the wiring between pinned submodules. The complete local and CI entry point is:

```bash
make ci
```

## Coverage matrix

| Gate | Coverage | Failure signal |
|---|---|---|
| `make verify` | Recursive submodules, clean submodule worktrees, identical glyph mirror commits, fixture/snapshot inventory | Missing, uninitialized, dirty, divergent, or orphaned inputs |
| `make smoke` | Direct kaster, microspell, and Tarot examples; semantic output from every glyph example | Helm error, empty trinket output, or an untracked empty glyph render |
| `make test all` | Canonical glyphs through kaster, summon examples, and librarian books | Render error, missing snapshot, or golden diff |
| `make test integration` | Aggregate-repository Librarian bootstrap followed by real Kaster, Summon, Microspell, Tarot, and Covenant renders | Broken bootstrap, inheritance, source routing, Lexicon resolution, or child chart contract |
| `make test covenant` | Direct Covenant compilation, application-contract scanning, and deterministic alphabetical principal sharding | Broken IAM contract, cross-book scan, or nondeterministic partitioning |

The snapshot suite currently covers 150 canonical glyph fixtures, 39 summon
fixtures, and 1 deployable book. Kaster and the two trinkets add 19 direct
smoke renders.

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

```bash
make snapshot glyph vault policy-role
make test glyph vault policy-role
make snapshot all
make test all
```

Review every golden diff before committing it. `make verify` rejects missing
and orphaned snapshots, so deleting or renaming a fixture requires the matching
snapshot change.

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

The suite requires Bash, GNU Make, Git, Helm, GNU diffutils, jq, ripgrep, and
the Python `yq` package. Covenant relies on Python `yq` syntax (`-y`, `-S`, and
`env`) and is not compatible with the unrelated Go `yq` binary.

The Forgejo workflow pins:

- Helm `3.20.2`, verified with its upstream SHA-256 checksum.
- Python `yq` `3.4.3`.
- Forgejo checkout v6 by commit SHA.
- The Node 24 Bookworm job image by OCI digest.

## Forgejo setup

The aggregate repository and all nested submodules are private SSH repositories.
Configure these repository or organization secrets before enabling the workflow:

- `RUNIK_SUBMODULE_SSH_KEY`: a read-only machine/deploy private key accepted by
  every Runik submodule repository.
- `RUNIK_SUBMODULE_KNOWN_HOSTS`: the pinned SSH host-key line for
  your Forgejo host, for example `[git.example.com]:2222`.

The workflow targets the conventional Forgejo runner label `docker`. If the
instance uses another label, change `runs-on` to the label shown under the
repository's Actions runner settings. Keep the runner containerized and
unprivileged; this suite does not need a Docker socket or cluster credentials.
