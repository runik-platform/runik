(.spec.sources | length) == 4
and .spec.sources[0].kustomize == $fixture[0].kustomize
and (.spec.sources[0] | has("helm") | not)
and .spec.sources[0].path == "config/default"
and .spec.sources[0].targetRevision == "upstream"
and (.spec.sources[1].repoURL | endswith("/kaster.git"))
and (.spec.sources[1] | has("helm"))
and (.spec.sources[1] | has("kustomize") | not)
and (.spec.sources[1].helm.valuesObject | has("kustomize") | not)
and .spec.sources[2].kustomize == $fixture[0].runes[0].kustomize
and (.spec.sources[2] | has("helm") | not)
and .spec.sources[3].chart == "database"
and .spec.sources[3].helm.valuesObject.replicas == 1
and (.spec.sources[3] | has("kustomize") | not)
