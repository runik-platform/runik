# Covenant example IAM book

This directory is the Covenant book. It is separate from the deployable
`example-book` and intentionally follows Covenant's multi-file contract:

```text
covenant-example/
├── index.yaml
├── identity/
│   ├── principals/
│   └── groups/
├── authorization/
│   ├── roles/
│   └── bindings/
└── keycloak/
    ├── realm-roles/
    ├── client-scopes/
    ├── idps/
    └── auth-flows/
```

`index.yaml` defines one organization and realm and selects
`example-book` as its application-contract source. Every other YAML file owns
exactly one identity, authorization, or Keycloak definition. Application
roles and clients remain with the deployable service spells and are discovered
through `sources.applicationBooks`; they are not duplicated here.

The deployment launcher is
`bookrack/example-book/infrastructure/covenant.yaml`. Librarian turns that
ordinary spell into an Argo CD Application for `runik.git/covenant`. Covenant
then follows `covenant/bookrack -> ../bookrack`, selects this directory by the
Helm release name `covenant-example`, and compiles all of these files together.
