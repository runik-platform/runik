# Kustomize path sources

For a Git repository containing a Kustomize base, declare `path`, `repository`,
`revision` and a `kustomize` map in the spell:

```yaml
name: operator
repository: https://git.example.com/platform/operator.git
path: config/default
revision: v1.0.0
kustomize:
  images:
    - controller=registry.example.com/operator:1.0.0
  replicas:
    - name: controller-manager
      count: 2
```

Librarian emits these options on the primary ArgoCD source:

```yaml
spec:
  sources:
    - repoURL: https://git.example.com/platform/operator.git
      path: config/default
      targetRevision: v1.0.0
      kustomize:
        images:
          - controller=registry.example.com/operator:1.0.0
        replicas:
          - name: controller-manager
            count: 2
```

The map uses [ArgoCD's Kustomize options](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/).
Librarian passes it through without interpreting images, patches, components or
other Kustomize settings. The installed ArgoCD version validates and executes
those options. Image names must match the base's image names.

## Additional sources

A Git-based rune accepts its own `kustomize` map:

```yaml
name: service
image: registry.example.com/service:1.0.0
runes:
  - repository: https://git.example.com/platform/operator.git
    path: config/default
    revision: v1.0.0
    kustomize:
      images:
        - controller=registry.example.com/operator:1.0.0
```

Each map applies only to its declaring source. Primary-source options do not
propagate to runes or trinkets such as Kaster. Helm runes can coexist with
Kustomize sources in the same Application.

## Renderer selection and validation

- `kustomize` requires `path` and cannot be combined with `chart`.
- Its value must be a map. Strings, lists and `null` fail during Helm rendering.
- An empty map (`kustomize: {}`) explicitly selects Kustomize with its defaults.
- A source with `kustomize` emits no `helm` block, including when `noHelm` is false
  or omitted. `values` is Helm-specific and does not configure Kustomize.
- Sources without `kustomize` retain the previous behavior: Helm by default, or
  ArgoCD tool detection when `appParams.noHelm: true` is set.

Keep deployment-specific image references in the consumer spell. The referenced
repository can retain a generic image placeholder, and its installer can choose
an image independently when built.

## Contract tests

From the Runik repository, run `make test-librarian`. The suite uses the existing
Runik toolchain: Bash, Helm, `yq`, `jq`, diffutils and ripgrep. It uses temporary
books and checks source routing,
option preservation, compatibility with existing Helm and `noHelm` sources,
empty maps and invalid definitions. It needs no cluster or registry access.

The complete Application baselines in `tests/librarian/kustomize/existing-applications.json`
were rendered with Librarian commit `9462268`, before Kustomize support. Tests
compare current output with those baselines for omitted and explicit `noHelm`
settings; adding the optional field does not alter existing source behavior.

Fixtures and assertions belong to Runik. The Librarian repository remains a
minimal renderer; this suite checks the selected `LIBRARIAN_DIR` checkout and
runs in both `make ci` and `make ci-component-candidate COMPONENT=librarian`.
