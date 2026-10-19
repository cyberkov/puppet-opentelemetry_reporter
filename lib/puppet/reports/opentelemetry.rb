# frozen_string_literal: true

require 'puppet'

# Loaded relative to this file so the processor works both when installed as a
# Puppet module and when copied into a report directory alongside lib/.
$LOAD_PATH.unshift(File.expand_path('../..', __dir__)) unless $LOAD_PATH.include?(File.expand_path('../..', __dir__))

require 'puppet_x/opentelemetry_reporter/config'
require 'puppet_x/opentelemetry_reporter/sdk'
require 'puppet_x/opentelemetry_reporter/metrics'
require 'puppet_x/opentelemetry_reporter/traces'

# Exports Puppet run telemetry over OTLP.
#
# Configuration is read from otel.yaml next to puppet.conf, falling back to the
# standard OTEL_* environment variables. See the README for installation.
Puppet::Reports.register_report(:opentelemetry) do
  desc <<~DESC
    Exports Puppet run metrics, and optionally traces, to an OpenTelemetry
    collector using OTLP.

    Configuration is read from `otel.yaml` in the same directory as
    `puppet.conf`, and from the standard `OTEL_*` environment variables.
    The file takes precedence over the environment.

    Traces are opt-in via `traces.enabled`, because one span per resource is
    a large volume of data for a big catalog.
  DESC

  def process
    config = PuppetX::OpentelemetryReporter::Config.from_confdir(File.dirname(Puppet.settings[:config]))

    return unless config.enabled?
    return unless config.report_environment?(environment)

    # The two signals are independent: metrics may be disabled while traces
    # are on, so neither guard may short circuit the other.
    recorded = false
    recorded |= record_metrics(config) if config.metrics_enabled?
    recorded |= record_traces(config) if config.traces_enabled?

    # Exported immediately rather than waiting for the periodic reader, because
    # a JRuby instance may be evicted from the pool before the next tick.
    PuppetX::OpentelemetryReporter::SDK.force_flush if recorded
  rescue StandardError => e
    # A telemetry failure must never fail an agent run.
    Puppet.err("opentelemetry_reporter: could not process report: #{e.class}: #{e.message}")
  end

  # @return [Boolean] whether anything was recorded, which decides if a flush
  #   is worth doing.
  def record_metrics(config)
    meter = PuppetX::OpentelemetryReporter::SDK.meter(config)
    return false if meter.nil?

    PuppetX::OpentelemetryReporter::SDK.metrics(meter, node_attribute: config.node_attribute?).record(self)
    true
  end

  # @return [Boolean] whether anything was recorded.
  def record_traces(config)
    tracer = PuppetX::OpentelemetryReporter::SDK.tracer(config)
    return false if tracer.nil?

    PuppetX::OpentelemetryReporter::Traces.new(tracer, node_attribute: config.node_attribute?).record(self)
    true
  end
end
