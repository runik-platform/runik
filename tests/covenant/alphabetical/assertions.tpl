{{- $plan := include "covenant.compile" . | fromJson -}}
{{- $emails := list -}}
{{- range $intent := $plan.intents -}}
  {{- if eq $intent.type "keycloak.principal" -}}
    {{- $email := $intent.spec.email -}}
    {{- $expected := substr 0 1 $email -}}
    {{- if regexMatch "^[0-9]" $email -}}{{- $expected = "0-9" -}}{{- end -}}
    {{- if ne $intent.principalShard $expected -}}
      {{- fail (printf "principal %s must belong to %s, got %s" $email $expected $intent.principalShard) -}}
    {{- end -}}
    {{- $emails = append $emails $email -}}
  {{- end -}}
{{- end -}}
{{- if not (has "a.z@example.test" $emails) -}}{{- fail "alphabetical fixture was not loaded" -}}{{- end -}}
{{- if ne (toJson $emails) (toJson (sortAlpha $emails)) -}}
  {{- fail "principal intents must be ordered by generated email" -}}
{{- end -}}
