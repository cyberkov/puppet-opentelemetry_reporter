# puppet-opentelemetry_reporter

A Puppet/OpenVox report processor that exports Puppet run metrics, and
optionally traces, to an OpenTelemetry collector over OTLP.

Metric names use the OpenTelemetry dot separator. The Collector's Prometheus
exporter rewrites dots to underscores, so `puppet.report.resources` is
published as `puppet_report_resources` — the same series name the
`prometheus` report processor produced. Existing dashboards keep working.

## Requirements

- OpenVox Server or Puppet Server
- The OpenTelemetry Ruby gems, installed into the server's own gem path

## Installation

### 1. Install the gems

The report processor runs inside the server's JRuby, so the gems must be
installed with `puppetserver gem`, not the system `gem`:

```bash
puppetserver gem install opentelemetry-sdk \
                         opentelemetry-metrics-sdk \
                         opentelemetry-exporter-otlp-metrics
```

Traces additionally require the OTLP span exporter. Install it only if you
intend to enable `traces.enabled`:

```bash
puppetserver gem install opentelemetry-exporter-otlp
```

If the gems are missing the processor logs a warning and disables itself.
It will not fail an agent run.

### 2. Install the module

Install the module on the server, for example into the `production`
environment or the global module path:

```bash
puppet module install voxpupuli-opentelemetry_reporter \
  --modulepath /etc/puppetlabs/code/modules
```

It depends on `puppetlabs-stdlib`. The module directory must be named
`opentelemetry_reporter`. Puppet Server syncs the report processor and its
`PuppetX::OpentelemetryReporter` library from it by pluginsync.

### 3. Configure the collector endpoint

Declare the class on the server. It manages only
`/etc/puppetlabs/puppet/otel.yaml`:

```puppet
class { 'opentelemetry_reporter':
  endpoint       => 'http://collector.example.com:4318',
  service_name   => 'openvox-server',
  traces_enabled => true,
}
```

Every parameter except `enabled` is optional. A parameter left unset is
omitted from the file, so the matching `OTEL_*` environment variable still
applies. This matters for `headers`, which replaces
`OTEL_EXPORTER_OTLP_HEADERS` when present. The file defaults to owner `root`,
group `puppet` and mode `0640`, because it can hold a token.

The class does **not** edit `puppet.conf` or restart the server (see step 4).
With `manage_gems => true` it also installs the gems from step 1 using the
`puppetserver_gem` package provider, which your Puppet version has to supply.
It is off by default, so the manual `puppetserver gem install` above stays
valid.

#### Alternative: single drop-in file

Without the module, build the self-contained processor and copy it over:

```bash
bundle exec rake dist:build
install -D -m 0644 dist/opentelemetry.rb \
  /etc/puppetlabs/puppet/lib/puppet/reports/opentelemetry.rb
```

`dist/` is not committed, because `lib/` is the single source of truth. In
this mode write `otel.yaml` yourself. Copy the sample configuration to
`/etc/puppetlabs/puppet/otel.yaml` (next to `puppet.conf`):

```yaml
endpoint: http://collector.example.com:4318
service_name: openvox-server
```

Every key is optional, and the file itself may be omitted — see
[`examples/otel.yaml`](examples/otel.yaml) for the fully documented set.

### 4. Enable the report processor

In `puppet.conf` on the server, add `opentelemetry` to the `reports`
setting:

```ini
[master]
reports = store,opentelemetry
```

Then restart the server:

```bash
systemctl restart puppetserver
```

## Configuration

Values are resolved highest precedence first:

1. a key in `otel.yaml`
2. the standard `OTEL_*` environment variable, where one exists
3. the built-in default

An absent file is legal — the processor can be configured entirely from the
environment. A file that *exists but cannot be parsed* is an error, because
that is a misconfiguration rather than an absence of one.

| Key | Environment variable | Default | Notes |
| --- | --- | --- | --- |
| `enabled` | — | `true` | Master switch. |
| `endpoint` | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Base URL; `/v1/metrics` is appended automatically. |
| `service_name` | `OTEL_SERVICE_NAME` | `openvox-server` | Identifies the emitting server. |
| `timeout` | `OTEL_EXPORTER_OTLP_TIMEOUT` | `10` | **Seconds in the file, milliseconds in the environment variable.** |
| `export_interval` | — | `30` | Seconds. Backstop only; reports flush on arrival. |
| `resource_attributes` | `OTEL_RESOURCE_ATTRIBUTES` | — | Merged; file entries win. |
| `headers` | `OTEL_EXPORTER_OTLP_HEADERS` | — | If set in the file it **replaces** the environment variable. |
| `environments` | — | all | Allowlist of Puppet environments. |
| `metrics.enabled` | — | `true` | |
| `metrics.node_attribute` | — | `true` | Set `false` to drop `puppet.node.name` and bound cardinality. |
| `traces.enabled` | — | `false` | Opt-in; one span per resource. See [Traces](#traces). |

### Cardinality

`puppet.node.name` is attached to every data point, so the number of time
series grows with the number of nodes. On large installations set
`metrics.node_attribute: false` to aggregate nodes together, trading
per-node detail for a bounded series count.

Note that the node name is a **data point attribute**, not a resource
attribute. A resource describes the process emitting the telemetry, and one
server reports on behalf of many nodes.

## Metrics

All metrics carry `puppet.node.name` (unless disabled) and
`deployment.environment.name`.

| Metric | Unit | Prometheus name | Description |
| --- | --- | --- | --- |
| `puppet.report.resources` | `1` | `puppet_report_resources` | Resources by state. |
| `puppet.report.time` | `s` | `puppet_report_time` | Time by resource type. |
| `puppet.report.changes` | `1` | `puppet_report_changes` | Changed resources. |
| `puppet.report.events` | `1` | `puppet_report_events` | Resource application events. |
| `puppet.report.duration` | `s` | `puppet_report_duration` | Total run duration. |
| `puppet.report.last_run.timestamp` | `s` | `puppet_report_last_run_timestamp` | Unix time of the last run. |
| `puppet.run.status` | `1` | `puppet_run_status` | One series per status. |
| `puppet.cached_catalog.status` | `1` | `puppet_cached_catalog_status` | One series per status. |
| `puppet.transaction.completed` | `1` | `puppet_transaction_completed` | `1` if the transaction completed. |

The four report categories break down by `puppet.metric.name`, which holds
the machine-readable id (`total`, `changed`, `failed`, …) rather than the
human-readable label, because attribute values must be bounded and
machine-readable.

`puppet.run.status` and `puppet.cached_catalog.status` emit one series per
possible status with exactly one set to `1`. This lets a query select on the
status without the value itself being an opaque enumeration:

```promql
puppet_run_status{puppet_run_status="failed"} == 1
```

## Traces

Traces are **opt-in**. Enable them in `otel.yaml`:

```yaml
traces:
  enabled: true
```

They are off by default because one span is emitted per resource: a catalog
with thousands of resources produces thousands of spans per run, for every
node. Enable them deliberately, and preferably with sampling configured in
the collector.

Each run becomes one trace:

- a root `puppet.run` span covering the run
- one child span per evaluated resource, named after the resource
  (`File[/tmp/example]`)

Because a report only arrives *after* the run has finished, spans are back
dated to the times the agent recorded rather than the time of export. The
root span's duration comes from the report's own `time` metric, so it agrees
with `puppet.report.duration`. A failed run, and each failed resource, is
marked with span status `ERROR`.

| Attribute | On | Description |
| --- | --- | --- |
| `puppet.node.name` | root | Reported node (unless disabled). |
| `deployment.environment.name` | root | Puppet environment. |
| `puppet.run.status` | root | `failed`, `changed` or `unchanged`. |
| `puppet.cached_catalog_status` | root | Whether a cached catalog was used. |
| `puppet.transaction.uuid` | root | Correlates with the report. |
| `puppet.resource.type` | resource | e.g. `File`, `Package`. |
| `puppet.resource.title` | resource | e.g. `/tmp/example`. |
| `puppet.resource.changed` | resource | Whether the resource changed. |
| `puppet.resource.out_of_sync` | resource | Whether it was out of sync. |
| `puppet.resource.failed` | resource | Whether it failed. |
| `code.file.path` | resource | Manifest that declared the resource. |
| `code.line.number` | resource | Line within that manifest. |

Skipped resources produce no span, because they were never evaluated and so
have no duration to show.

Traces need the `opentelemetry-exporter-otlp` gem and a `traces` pipeline in
the collector; `/v1/traces` is appended to `endpoint` automatically.

## Trying it locally

Start a collector:

```bash
podman run --rm -p 4318:4318 -p 8889:8889 \
  -v ./examples/otel-collector.yaml:/etc/otelcol-contrib/config.yaml:z \
  docker.io/otel/opentelemetry-collector-contrib:latest
```

Metrics are then scrapeable at <http://localhost:8889/metrics>, and arriving
reports are echoed to the collector log by the `debug` exporter. See
[`examples/otel-collector.yaml`](examples/otel-collector.yaml).

## Failure behaviour

A telemetry failure must never fail an agent run. Every error path — missing
gems, an unreachable collector, a malformed report — is logged through
`Puppet.err` and swallowed. The only hard error is a malformed `otel.yaml`,
which is reported at startup as a misconfiguration.

Reports are flushed as they arrive rather than waiting for the periodic
reader, because a JRuby instance may be evicted from the pool before the
next tick.

## Development

```bash
bundle install
bundle exec rake spec        # unit and rspec-puppet tests
bundle exec rake dist:build  # build the single-file processor
```

## License

Apache-2.0
