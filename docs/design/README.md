# Runik Design Documentation

This documentation is intended for platform engineers who want to understand
Runik internals, extend the system, or create custom glyphs and trinkets.

## Reading Order

Start with **architecture.md** to get the full system overview, then read
**librarian.md** to understand two-pass processing, followed by
**rendering-pipeline.md** for the end-to-end flow. After that, read the
remaining documents as needed.

## Document Index

### System Overview

- **architecture.md** -- System overview, data flow, technology stack
- **rendering-pipeline.md** -- Complete flow from spell to Kubernetes resources
- **architectural-decisions.md** -- Why copy vs deps, multi-source, lexicon, two-pass

### Core Components

- **librarian.md** -- Two-pass processing, detection logic, stripping, context passing
- **summon-internals.md** -- Template structure, workload switching, contentType system
- **kaster.md** -- Glyph orchestrator, dispatch logic, Go template code
- **lexicon.md** -- Runic Indexer, selection algorithm, query format

### Primitives

- **glyphs.md** -- Glyph anatomy, type system, submodule distribution
- **mongodb-glyph.md** -- Percona lifecycle and generic MongoDB database/user operations
- **trinkets.md** -- Registration, trigger mechanism, internal design
- **merge-system.md** -- Cascading merge, appendix, localAppendix, defaultTrinket

### Extending Runik

- **creating-glyphs.md** -- Step-by-step guide to create a custom glyph
- **creating-trinkets.md** -- Step-by-step guide to create a custom trinket
