# Covenant render fixture

The fixture exercises the Covenant compiler without deploying resources:

- `covenant-example` is direct IAM input for one organization and realm, with
  one-entity files for
  principals, identity-only groups, authorization roles, single-role bindings,
  Keycloak realm roles and scopes, an identity provider, and an authentication
  flow.
- `example-book` is an ordinary deployable Librarian book. Its service spells
  publish OIDC public/confidential, SAML, and service-account contracts. The
  console contract also
  contains a second realm entry to prove that each IAM book selects only its
  own client instance.

Run `make test covenant` with Helm and `yq`. The test invokes Covenant directly,
renders the realm and the ApplicationSet's child payloads through the same
chart, and checks identity derivation, OIDC, SAML, Vault-backed IDP credentials,
auth flows, application scanning, and resource ordering. Librarian does not
render the IAM input.

`make test integration` covers the deployment path separately. It starts from
the aggregate `bookdeclaration.yaml`, renders `example-book` through
`librarian/bookrack -> ../bookrack`, extracts the generated `covenant-example`
Application values, and renders `runik.git/covenant` against the same IAM input.
The deployment spell is `example-book/infrastructure/covenant.yaml`; it is not
the IAM book itself.

The YAML fixtures and Helm assertions in `alphabetical/` also test email
ordering, numeric initials, filename and profile independence, stable membership
when users are added or removed, and removal of empty groups. These tests never
contact a cluster.
