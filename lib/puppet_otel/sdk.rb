# frozen_string_literal: true

require 'socket'
require 'puppet_otel/config'

module PuppetOtel
  # Lazily builds and owns the OpenTelemetry MeterProvider for this process.
  #
  # OpenVox Server runs many JRuby instances inside one JVM. Each instance
  # loads this file separately, so the provider is built once per instance,
  # guarded by a mutex. A MeterProvider is constructed explicitly rather than
  # through OpenTelemetry::SDK.configure so that this module never mutates
  # global state that the host application may also be using.
  #
  # Every public entry point degrades to Puppet.err and never raises, because
  # a telemetry failure must not fail an agent run.
  module SDK
    MUTEX = Mutex.new
    INSTRUMENTATION_NAME = 'puppet-opentelemetry_reporter'
    INSTRUMENTATION_VERSION = '0.1.0'

    class << self
      # @return [Object, nil] the meter, or nil when telemetry is unavailable.
      def meter(config)
        provider = meter_provider(config)
        return nil if provider.nil?

        @meter ||= provider.meter(INSTRUMENTATION_NAME, version: INSTRUMENTATION_VERSION)
      rescue StandardError => e
        log_error('could not create meter', e)
        nil
      end

      # Exports anything buffered. Called after each report so that telemetry
      # is not lost when a JRuby instance is evicted from the pool before the
      # periodic reader next fires.
      def force_flush
        provider = @meter_provider
        return if provider.nil?

        provider.force_flush
      rescue StandardError => e
        log_error('could not flush metrics', e)
      end

      def shutdown
        provider = @meter_provider
        return if provider.nil?

        provider.shutdown
      rescue StandardError => e
        log_error('could not shut down meter provider', e)
      ensure
        reset!
      end

      # Discards the configured provider. Intended for tests.
      def reset!
        MUTEX.synchronize do
          @meter_provider = nil
          @meter = nil
          @configured = false
        end
      end

      def configured?
        @configured == true
      end

      private

      def meter_provider(config)
        return @meter_provider if @configured

        MUTEX.synchronize do
          # Checked again inside the lock: another thread may have configured
          # the provider while this one waited.
          next if @configured

          @meter_provider = build_meter_provider(config)
          @configured = true
          install_at_exit_hook if @meter_provider
        end

        @meter_provider
      end

      def build_meter_provider(config)
        require 'opentelemetry/sdk'
        require 'opentelemetry-metrics-sdk'
        require 'opentelemetry/exporter/otlp_metrics'

        exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new(
          endpoint: metrics_endpoint(config),
          headers: config.headers,
          timeout: config.timeout,
        )

        reader = OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(
          export_interval_millis: (config.export_interval * 1000).to_i,
          export_timeout_millis: (config.timeout * 1000).to_i,
          exporter: exporter,
        )

        provider = OpenTelemetry::SDK::Metrics::MeterProvider.new(resource: resource(config))
        provider.add_metric_reader(reader)
        provider
      rescue LoadError => e
        log_error('OpenTelemetry gems are not available, telemetry is disabled', e)
        nil
      rescue StandardError => e
        log_error('could not configure OpenTelemetry', e)
        nil
      end

      # The OTLP metrics exporter expects the signal specific path. A bare base
      # endpoint is the common configuration, so the path is appended unless
      # the user already supplied one.
      def metrics_endpoint(config)
        endpoint = config.endpoint.to_s.sub(%r{/+\z}, '')
        return endpoint if endpoint.end_with?('/v1/metrics')

        "#{endpoint}/v1/metrics"
      end

      # Describes the OpenVox Server process emitting the telemetry. The node a
      # report is about is not part of the resource, because one process
      # reports on behalf of many nodes.
      def resource(config)
        attributes = {
          'service.name' => config.service_name,
          'service.version' => INSTRUMENTATION_VERSION,
          'host.name' => hostname,
        }
        attributes.merge!(config.resource_attributes)
        attributes.reject! { |_k, v| v.nil? || v.to_s.empty? }

        OpenTelemetry::SDK::Resources::Resource.create(attributes)
      end

      def hostname
        Socket.gethostname
      rescue StandardError
        nil
      end

      def install_at_exit_hook
        at_exit { shutdown }
      end

      def log_error(message, error)
        text = "opentelemetry_reporter: #{message}: #{error.class}: #{error.message}"
        if defined?(::Puppet) && ::Puppet.respond_to?(:err)
          ::Puppet.err(text)
        else
          warn(text)
        end
      end
    end
  end
end
