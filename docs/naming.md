# Naming decisions

Audited against released OpenTelemetry Semantic Conventions **v1.44.0**
(<https://github.com/open-telemetry/semantic-conventions/tree/v1.44.0>).

This module deliberately prefers OpenTelemetry naming over the label format used by
[puppet-prometheus_reporter](https://github.com/voxpupuli/puppet-prometheus_reporter).
Where the two differ, OpenTelemetry wins. Dashboard compatibility is preserved by the
OTLP -> Prometheus translation rules rather than by copying Prometheus names verbatim.

## Why existing dashboards still work

OpenTelemetry metric names use `.` as the namespace separator. The Prometheus exporter in
the OpenTelemetry Collector translates `.` to `_`. So `puppet.report.resources` is exposed
to Prometheus as `puppet_report_resources` -- the same series name the Prometheus reporter
produced. Following OTel conventions and keeping existing dashboards are therefore *not*
in conflict for the metric names themselves.

Attribute names are a genuine divergence and are documented below.

## Resource vs. data point attributes

A Resource describes *the process emitting the telemetry*. The report processor runs inside
the OpenVox Server process and receives reports from many different agent nodes, so the
reported node is **not** a property of the emitting process.

Therefore:

- the **Resource** describes the OpenVox Server itself, and is fixed for the lifetime of
  the process
- the **reported node** (its name, environment and run status) is carried as **data point
  attributes**, because those values differ from one report to the next

### Resource attributes (describe the server)

| Attribute | Stability | Source |
|---|---|---|
| `service.name` | stable | `OTEL_SERVICE_NAME` / `otel.yaml`, default `openvox-server` |
| `service.version` | stable | this module's version |
| `host.name` | development | the hostname of the OpenVox Server process |

Caveat: `host.name` is only at `development` stability in v1.44.0. It is nevertheless the
correct released key for a host name and there is no stable alternative, so it is used as-is.

### Data point attributes (describe the reported node)

| Attribute | Stability | Source |
|---|---|---|
| `deployment.environment.name` | stable | `report.environment` |
| `puppet.node.name` | custom | `report.host` |
| `puppet.run.status` | custom | `report.status` |

## Span attributes (traces)

Traces model one Puppet run as a trace: a root `puppet.run` span, with one child span
per evaluated resource. The root span carries the same data point attributes as the
metrics, so a query filters spans and metrics identically.

### Root span

| Attribute | Stability | Source |
|---|---|---|
| `deployment.environment.name` | stable | `report.environment` |
| `puppet.node.name` | custom | `report.host` |
| `puppet.run.status` | custom | `report.status` |
| `puppet.cached_catalog_status` | custom | `report.cached_catalog_status` |
| `puppet.transaction.uuid` | custom | `report.transaction_uuid` |

### Resource spans

| Attribute | Stability | Source |
|---|---|---|
| `puppet.resource.type` | custom | `status.resource_type` |
| `puppet.resource.title` | custom | `status.title` |
| `puppet.resource.changed` | custom | `status.changed` |
| `puppet.resource.out_of_sync` | custom | `status.out_of_sync` |
| `puppet.resource.failed` | custom | `status.failed` |
| `code.file.path` | development | `status.file` |
| `code.line.number` | development | `status.line` |

The `code.*` group is reused rather than inventing `puppet.resource.file`: a manifest
path and line *are* source code coordinates, which is exactly what the released group
describes. Both keys are at `development` stability in v1.44.0, but there is no stable
alternative and the semantics match, so they are used as-is.

The span **name** is the resource reference (`File[/tmp/example]`) rather than a generic
constant, because conventions require the name to identify what the span represents while
staying bounded. A resource reference is already the catalog's own bounded identifier.

### Timestamps

A report arrives only after the run has finished, so spans are back dated to the times the
agent recorded rather than the time of export. The root span's duration is taken from the
report's `time` metric rather than a wall clock, so it agrees with `puppet.report.duration`
instead of including export latency.

A resource without its own timestamp is placed at the run's start time, which keeps it
inside its parent rather than inventing a position for it.

### Status

A failed run, and each failed resource, sets span status `ERROR`. A successful span is
left `UNSET` rather than explicitly `OK`, per the conventions: `OK` is reserved for an
explicit assertion by the application, not the default for "nothing went wrong".

Skipped resources produce no span at all, because they were never evaluated and so have no
duration to represent.

## Cardinality

Attaching the node name to every data point means the number of series scales with the
number of managed nodes. That is inherent to per-node reporting and cannot be avoided by
moving the attribute to the Resource, since one process reports for all nodes.

For large installations `node_attribute: false` omits `puppet.node.name`, which aggregates
all nodes into per-environment series.

## Divergence from the Prometheus reporter

| Prometheus reporter label | This module | Rationale |
|---|---|---|
| `host="..."` | `puppet.node.name` | Namespaced; no released key exists for "the node a report is about" |
| `environment="..."` | `deployment.environment.name` | `deployment.environment.name` is **stable** in v1.44.0 |
| `name="Total"` (capitalised label) | `puppet.metric.name="total"` (machine-readable id) | Conventions require lowercase, bounded values. The report's machine id is used, not its display label |
| `state="failed"` | `puppet.run.status="failed"` | Namespaced under a stable custom prefix |

## Rejected: the `cicd` group

The `cicd` group was evaluated and rejected. All of its attributes are at
`release_candidate` stability, and it models CI/CD pipelines, workers and tasks. A Puppet
agent run is configuration convergence, not a pipeline execution. Per the selection rules,
a stable custom namespace is used instead where no released key fits.

## Adopted released keys

| Attribute | Stability | Use |
|---|---|---|
| `error.type` | stable | Classification of a failed Puppet run |

## Custom `puppet.*` namespace

Used only where no released key exists. All values are bounded (enumerations or the
report's own machine-readable metric ids).

| Attribute | Values |
|---|---|
| `puppet.run.status` | `failed`, `changed`, `unchanged` |
| `puppet.metric.name` | report metric id, e.g. `total`, `skipped`, `failed`, `config_retrieval` |
| `puppet.cached_catalog_status` | `not_used`, `explicitly_requested`, `on_failure` |
| `puppet.noop` | `true` / `false` |
| `puppet.transaction.uuid` | the report's transaction uuid (spans only) |
| `puppet.resource.type` | resource type, e.g. `File`, `Package` (spans only) |
| `puppet.resource.title` | resource title (spans only) |
| `puppet.resource.changed` | `true` / `false` (spans only) |
| `puppet.resource.out_of_sync` | `true` / `false` (spans only) |
| `puppet.resource.failed` | `true` / `false` (spans only) |

## Units

Units are declared on the instrument rather than encoded in the name, per the conventions:
`s` for durations, `1` for counts.
