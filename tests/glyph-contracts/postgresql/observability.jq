# Assertions consume real Kaster/Summon output and decoded provisioning files.
def check($condition; $message):
  if $condition then . else error($message) end;
def cluster($name): [.[] | select(.kind == "Cluster" and .metadata.name == $name)][0];
def rules($name): [$alerts[0][] | .groups[]?.rules[]? | select(.labels.cnpg_cluster == $name)];
def rule($name; $title): [rules($name)[] | select(.title | startswith($title + " /"))][0];
def query($name; $title): rule($name; $title).data[0].model.expr;

check(([.[] | select(.kind == "Cluster")] | length) == 7; "expected seven PostgreSQL clusters")
| check(cluster("small").spec.storage.size == "1Gi" and cluster("large").spec.storage.size == "500Gi";
        "cluster storage overrides must remain independent")
| check(cluster("large").spec.instances == 3 and cluster("small").spec.instances == 1;
        "instance count overrides must remain independent")
| check(all(.[] | select(.kind == "Cluster" and .metadata.name != "unmonitored");
            .spec.inheritedMetadata.annotations["prometheus.io/scrape"] == "true"
            and .spec.inheritedMetadata.annotations["prometheus.io/port"] == "9187"
            and .spec.inheritedMetadata.annotations["prometheus.io/path"] == "/metrics");
        "standard CNPG metrics annotations are missing")
| check(cluster("unmonitored").spec.inheritedMetadata ==
        {labels: {team: "platform"}, annotations: {"example.com/owner": "db-team"}};
        "observability opt-out must preserve user metadata")
| check(cluster("custom").spec.monitoring.metricsQueriesTTL == 15
        and cluster("custom").spec.inheritedMetadata.labels.team == "platform"
        and cluster("custom").spec.inheritedMetadata.annotations["example.com/owner"] == "db-team";
        "monitoring and inherited metadata passthrough was lost")
| check(($dashboards[0] | length) == 5; "only monitored clusters with dashboards enabled should have dashboards")
| check(($dashboards[0] | map(.uid) | length) == ($dashboards[0] | map(.uid) | unique | length);
        "dashboard UIDs must be unique across clusters")
| check(all($dashboards[0][]; (.panels | length) >= 14 and all(.panels[].targets[]; .expr | contains("namespace=\"" + $namespace + "\"")));
        "dashboard queries must use their release namespace")
| check(all($alerts[0][] | .groups[]?.rules[]?;
            . as $rule | .labels.namespace == $namespace and (.uid | length) <= 40
            and (.data[0].model.expr | contains("namespace=\"" + $namespace + "\""))
            and ((.data[0].model.expr | contains("cnpg_cluster=\"" + $rule.labels.cnpg_cluster + "\""))
                 or (.data[0].model.expr | contains("kubelet_volume_stats"))));
        "alert queries and identities must be isolated by namespace and cluster")
| ([$alerts[0][] | .groups[]?.rules[]?.uid]) as $uids
| check(($uids | length) == ($uids | unique | length); "alert UIDs must be unique across clusters")
| check(query("large"; "PostgreSQLSlotRetainedWALHigh") | contains("kubelet_volume_stats_capacity_bytes");
        "slot warning must use filesystem capacity instead of a production-specific byte limit")
| check(rule("large"; "PostgreSQLSlotRetainedWALHigh").data[2].model.conditions[0].evaluator.params == [0.1];
        "default slot pressure ratio changed")
| check((rules("small") | any(.title | contains("StreamingReplicasMissing"))) == false
        and (query("large"; "PostgreSQLStreamingReplicasMissing") | contains("clamp_min(2 -"));
        "replication alerts must reflect the configured number of instances")
| check((rules("small") | any(.title | contains("Archiving"))) == false
        and ([rules("backed-up")[] | select(.title | contains("Archiving"))] | length) == 2;
        "archiving alerts must follow backup configuration")
| check(all(rules("backed-up")[] | select(.title | contains("Archiving")); .data[0].model.expr | contains("role=\"primary\""))
        and (query("large"; "PostgreSQLSlotRetainedWALHigh") | contains("role=\"primary\""));
        "mirrored standby slots must not cause primary-only alerts")
| check(query("backed-up"; "PostgreSQLWALArchivingStalled") | contains("value=\"ready\"");
        "idle databases must not cause stalled-archive alerts")
| check(query("small"; "PostgreSQLMetricsMissing") | contains("absent_over_time(");
        "missing exporter metrics need an explicit alert")
| check(query("small"; "PostgreSQLVolumeMetricsMissing") | contains("kubelet_volume_stats_available_bytes");
        "missing PVC free-space metrics must not be treated as a healthy filesystem")
| check(all(rules("custom")[]; .data[0].datasourceUid == "prometheus")
        and rule("custom"; "PostgreSQLDiskAlmostFull").data[2].model.conditions[0].evaluator.params == [0.7];
        "datasource and threshold overrides must be honored")
| check(all($alerts[0][] | select(has("groups") | not); (.deleteRules | length) == 16)
        and (rules("unmonitored") | length) == 0 and (rules("metrics-only") | length) == 0;
        "opt-out must explicitly delete previously provisioned rules")
| check(all($alerts[0][]; ([.groups[]?.rules[]?.uid] + [.deleteRules[]?.uid] | length) == 16
            and ([.groups[]?.rules[]?.uid] + [.deleteRules[]?.uid] | length) ==
                ([.groups[]?.rules[]?.uid] + [.deleteRules[]?.uid] | unique | length));
        "active and deleted rule sets must be complete and disjoint")
| true
