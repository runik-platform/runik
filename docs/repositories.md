# GitHub repositories

Runik is developed as an aggregate workspace, but deployable components live in
separate Git repositories. Public examples must use these GitHub source URLs:

| Component | Repository | Argo CD chart path |
|---|---|---|
| Aggregate workspace | `https://github.com/runik-platform/runik.git` | `librarian` and `covenant` for bundled books |
| Librarian | `https://github.com/runik-platform/librarian.git` | `.` |
| Covenant | `https://github.com/runik-platform/covenant.git` | `.` |
| Summon | `https://github.com/runik-platform/summon.git` | `.` |
| Kaster | `https://github.com/runik-platform/kaster.git` | `.` |
| Glyphs | `https://github.com/runik-platform/glyphs.git` | Library charts; consumed by Kaster, Summon, Microspell, Tarot, and Covenant |
| Microspell | `https://github.com/runik-platform/microspell.git` | `.` |
| Tarot | `https://github.com/runik-platform/tarot.git` | `.`; repository publication is pending |

Examples use the `upstream` branch unless they intentionally demonstrate a tag
or feature branch. Summon, Kaster, Microspell, and eventually Tarot can be used
directly as Argo CD sources because each repository root is its Helm chart.

Librarian and Covenant need the consumer's `bookrack/` at Helm render time.
When a book is bundled in the aggregate repository, Argo CD points to
`runik.git` with path `librarian` or `covenant`; each submodule tracks a
`bookrack -> ../bookrack` symlink that resolves the aggregate books. The root
`bookdeclaration.yaml` demonstrates that bootstrap.

A separate content repository uses the same layout by vendoring or submoduling
the chart beside its own `bookrack/` and pointing its bootstrap Application to
that content repository. Standalone component repositories remain their source
and release boundaries. Summon, Kaster, Microspell, and Tarot continue to use
their own repository URLs as generated child sources.
