# Translate the generated Grafana instant query and threshold, without copying PromQL.
[$alerts[0][] | .groups[]?.rules[]? | select(.labels.cnpg_cluster == "generic")]
| map({key: (.title | split(" / ")[0]), value: .}) | from_entries as $rules
| if $mode == "rules" then
    {groups: [{name: "postgresql", rules: [$rules | to_entries[] |
      {alert: .key, expr: ("(" + .value.data[0].model.expr + ") > " +
        (.value.data[2].model.conditions[0].evaluator.params[0] | tostring))}]}]}
  else
    $cases[0] | .tests[].promql_expr_test[] |= (
      $rules[.alert] as $rule
      | if $rule == null then error("unknown generated alert: " + .alert) else . end
      | .expr = (if .mode == "raw" then $rule.data[0].model.expr else
          "sum((" + $rule.data[0].model.expr + ") > bool " +
          ($rule.data[2].model.conditions[0].evaluator.params[0] | tostring) + ")" end)
      | del(.alert, .mode))
  end
