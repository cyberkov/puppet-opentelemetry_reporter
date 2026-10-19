# @summary Manages the otel.yaml configuration file of the OpenTelemetry report processor
#
# Only keys that are set are written to the file. Leaving a parameter at
# `undef` lets the processor fall back to the standard OTEL_* environment
# variable and then to its built-in default. This matters for `headers`: a key
# present in the file REPLACES OTEL_EXPORTER_OTLP_HEADERS instead of merging.
#
# The class does not touch puppet.conf or the puppetserver service. Add
# `opentelemetry` to the `reports` setting and restart the server yourself,
# with whatever tooling manages your server.
#
# @example Minimal
#   include opentelemetry_reporter
#
# @example Send to a collector and enable traces
#   class { 'opentelemetry_reporter':
#     endpoint       => 'http://collector.example.com:4318',
#     traces_enabled => true,
#     manage_gems    => true,
#   }
#
# @param enabled
#   Master switch of the processor.
# @param endpoint
#   Base OTLP HTTP endpoint of the collector. Environment: OTEL_EXPORTER_OTLP_ENDPOINT.
# @param service_name
#   The service.name of this server. Environment: OTEL_SERVICE_NAME.
# @param timeout
#   Export timeout in SECONDS. The environment variable is in milliseconds.
# @param export_interval
#   How often the periodic reader exports, in seconds.
# @param resource_attributes
#   Extra resource attributes, merged with OTEL_RESOURCE_ATTRIBUTES. Entries here win.
# @param headers
#   Headers sent with each OTLP request, for example a token. Replaces
#   OTEL_EXPORTER_OTLP_HEADERS when set. The file is not world readable for this reason.
# @param environments
#   Allowlist of Puppet environments to report on. Unset or empty reports on all.
# @param metrics_enabled
#   Whether to export metrics. The processor defaults to true.
# @param metrics_node_attribute
#   Whether to attach puppet.node.name to metrics. Disabling bounds cardinality.
# @param traces_enabled
#   Whether to export traces. The processor defaults to false because one span
#   is emitted per resource.
# @param confdir
#   Directory holding puppet.conf, which is where the processor looks for otel.yaml.
# @param owner
#   Owner of otel.yaml.
# @param group
#   Group of otel.yaml. Must be able to read it, as the server runs as this group.
# @param mode
#   Mode of otel.yaml.
# @param ensure
#   Whether otel.yaml should exist.
# @param manage_gems
#   Install the OpenTelemetry gems into the puppetserver gem path. Leave this
#   off if you install them by hand with `puppetserver gem install`.
# @param gem_ensure
#   Ensure value for the gems when manage_gems is true.
class opentelemetry_reporter (
  Boolean $enabled = true,
  Optional[String[1]] $endpoint = undef,
  Optional[String[1]] $service_name = undef,
  Optional[Numeric] $timeout = undef,
  Optional[Numeric] $export_interval = undef,
  Optional[Hash[String[1], String]] $resource_attributes = undef,
  Optional[Hash[String[1], String]] $headers = undef,
  Optional[Array[String[1]]] $environments = undef,
  Optional[Boolean] $metrics_enabled = undef,
  Optional[Boolean] $metrics_node_attribute = undef,
  Optional[Boolean] $traces_enabled = undef,
  String[1] $confdir = '/etc/puppetlabs/puppet',
  String[1] $owner = 'root',
  String[1] $group = 'puppet',
  String[1] $mode = '0640',
  Enum['present', 'absent'] $ensure = 'present',
  Boolean $manage_gems = false,
  String[1] $gem_ensure = 'installed',
) {
  $metrics = {
    'enabled'        => $metrics_enabled,
    'node_attribute' => $metrics_node_attribute,
  }.filter |$key, $value| { $value =~ NotUndef }

  $traces = {
    'enabled' => $traces_enabled,
  }.filter |$key, $value| { $value =~ NotUndef }

  $settings = {
    'enabled'             => $enabled,
    'endpoint'            => $endpoint,
    'service_name'        => $service_name,
    'timeout'             => $timeout,
    'export_interval'     => $export_interval,
    'resource_attributes' => $resource_attributes,
    'headers'             => $headers,
    'environments'        => $environments,
    'metrics'             => $metrics.empty ? { true => undef, default => $metrics },
    'traces'              => $traces.empty ? { true => undef, default => $traces },
  }.filter |$key, $value| { $value =~ NotUndef }

  file { "${confdir}/otel.yaml":
    ensure  => $ensure,
    owner   => $owner,
    group   => $group,
    mode    => $mode,
    content => stdlib::to_yaml($settings),
  }

  if $manage_gems {
    $base_gems = [
      'opentelemetry-sdk',
      'opentelemetry-metrics-sdk',
      'opentelemetry-exporter-otlp-metrics',
    ]

    # The span exporter is only needed once traces are switched on.
    $gems = $traces_enabled ? {
      true    => $base_gems + ['opentelemetry-exporter-otlp'],
      default => $base_gems,
    }

    package { $gems:
      ensure   => $gem_ensure,
      provider => 'puppetserver_gem',
    }
  }
}
