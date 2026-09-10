# Example book

This self-contained book demonstrates recognizable platform operations rather
than synthetic value-merging scenarios:

- install cert-manager from its upstream chart, publish the cluster-wide
  issuer from that spell, and materialize it through its ClusterIssuer glyph;
- provision a shared PostgreSQL cluster and have the Vault spell consume it;
- publish Vault and PostgreSQL coordinates globally from their producer spells;
- deploy Keycloak against the shared PostgreSQL service and publish it for IAM;
- invoke Covenant from the aggregate Runik repository to compile the separate
  `covenant-example` IAM input and the application contracts in this book;
- schedule a nightly backup through Summon;
- deploy web services through a chapter-level Microspell default and consume
  the published issuer for the console certificate;
- publish OIDC, public, SAML, and service-account contracts for Covenant;
- run a repository bootstrap process through Tarot while Summon materializes
  its Vault access.

The shapes are reduced and sanitized from production patterns used by The YAML
Life. They contain no TYL repository paths, hosts, credentials, or cluster data.
Runik components use their GitHub repositories and the `upstream` branch. The
Tarot URL is reserved for the repository that is still pending publication.

The repository-level `bookdeclaration.yaml` points Argo CD at `runik/librarian`.
The tracked `librarian/bookrack -> ../bookrack` symlink gives that chart access
to this example without copying the book or referencing another checkout.
