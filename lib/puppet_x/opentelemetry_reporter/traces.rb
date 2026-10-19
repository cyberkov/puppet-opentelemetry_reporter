# frozen_string_literal: true

# Time.parse lives in the stdlib extension, which is not loaded by default.
# Required explicitly rather than relying on Puppet having loaded it.
require 'time'

module PuppetX
  module OpentelemetryReporter
    # Translates a Puppet report into an OpenTelemetry trace.
    #
    # One run becomes a root "puppet.run" span, with a child span per resource
    # taken from the report's resource_statuses. That is why traces are opt-in:
    # a catalog with thousands of resources produces thousands of spans.
    #
    # Reports arrive after the run has finished, so the spans are back dated to
    # the times the agent recorded rather than the time of export. A resource
    # without its own timestamp is placed at the run's start time, which keeps
    # it inside the parent span instead of inventing a position for it.
    #
    # See docs/naming.md for the attribute decisions and their stability.
    class Traces
      ROOT_SPAN_NAME = 'puppet.run'

      def initialize(tracer, node_attribute: true)
        @tracer = tracer
        @node_attribute = node_attribute
      end

      # Records the trace derived from one report.
      #
      # @param report [Puppet::Transaction::Report] or any object answering the
      #   same methods.
      def record(report)
        started_at = start_time(report)
        finished_at = end_time(report, started_at)

        root = @tracer.start_root_span(
          ROOT_SPAN_NAME,
          attributes: root_attributes(report),
          start_timestamp: started_at,
          kind: :internal,
        )

        mark_status(root, failed?(report))

        begin
          OpenTelemetry::Trace.with_span(root) do
            record_resources(report, started_at)
          end
        ensure
          root.finish(end_timestamp: finished_at)
        end
      end

      private

      # Attributes common to the whole run. The node is identified here and not
      # on the resource, because one server process reports for many nodes.
      def root_attributes(report)
        attributes = {}

        environment = value_of(report, :environment)
        attributes['deployment.environment.name'] = environment.to_s unless nil_or_empty?(environment)

        if @node_attribute
          host = value_of(report, :host)
          attributes['puppet.node.name'] = host.to_s unless nil_or_empty?(host)
        end

        status = value_of(report, :status)
        attributes['puppet.run.status'] = status.to_s unless nil_or_empty?(status)

        cached = value_of(report, :cached_catalog_status)
        attributes['puppet.cached_catalog_status'] = cached.to_s unless nil_or_empty?(cached)

        uuid = value_of(report, :transaction_uuid)
        attributes['puppet.transaction.uuid'] = uuid.to_s unless nil_or_empty?(uuid)

        attributes
      end

      def failed?(report)
        value_of(report, :status).to_s == 'failed'
      end

      def record_resources(report, run_started_at)
        statuses = value_of(report, :resource_statuses)
        return unless statuses.respond_to?(:each_value)

        statuses.each_value do |status|
          record_resource(status, run_started_at)
        rescue StandardError
          # One malformed resource status must not discard the whole trace.
          next
        end
      end

      def record_resource(status, run_started_at)
        # Skipped resources were never evaluated, so they have no duration worth
        # a span of their own.
        return if truthy?(value_of(status, :skipped))

        title = value_of(status, :resource) || value_of(status, :title)
        return if nil_or_empty?(title)

        started_at = time_of(status) || run_started_at
        duration = value_of(status, :evaluation_time)
        duration = 0.0 unless duration.is_a?(Numeric)

        span = @tracer.start_span(
          title.to_s,
          attributes: resource_attributes(status),
          start_timestamp: started_at,
          kind: :internal,
        )
        mark_status(span, truthy?(value_of(status, :failed)))
        span.finish(end_timestamp: started_at + duration)
      end

      def resource_attributes(status)
        attributes = {}

        type = value_of(status, :resource_type)
        attributes['puppet.resource.type'] = type.to_s unless nil_or_empty?(type)

        title = value_of(status, :title)
        attributes['puppet.resource.title'] = title.to_s unless nil_or_empty?(title)

        attributes['puppet.resource.changed'] = truthy?(value_of(status, :changed))
        attributes['puppet.resource.out_of_sync'] = truthy?(value_of(status, :out_of_sync))
        attributes['puppet.resource.failed'] = truthy?(value_of(status, :failed))

        # Where the resource was declared, which is what an operator needs in
        # order to act on a slow or failing resource.
        file = value_of(status, :file)
        attributes['code.file.path'] = file.to_s unless nil_or_empty?(file)

        line = value_of(status, :line)
        attributes['code.line.number'] = line.to_i if line.is_a?(Numeric)

        attributes
      end

      def mark_status(span, failed)
        return unless failed

        span.status = OpenTelemetry::Trace::Status.error
      end

      def start_time(report)
        time_of(report) || Time.now
      end

      # The run's duration comes from the metrics rather than a wall clock, so
      # the span length matches the duration reported elsewhere.
      def end_time(report, started_at)
        started_at + total_time(report)
      end

      def total_time(report)
        metrics = value_of(report, :metrics)
        return 0.0 unless metrics.respond_to?(:[])

        time = metrics['time']
        return 0.0 if time.nil? || !time.respond_to?(:values)

        entry = time.values.find { |e| e.respond_to?(:[]) && e[0].to_s == 'total' }
        (entry && entry[2].is_a?(Numeric)) ? entry[2] : 0.0
      end

      def time_of(object)
        value = value_of(object, :time)
        return value if value.is_a?(Time)
        return nil if nil_or_empty?(value)

        begin
          Time.parse(value.to_s)
        rescue StandardError
          nil
        end
      end

      # Reads an attribute defensively. Report objects differ between Puppet
      # versions, and a missing method must never fail an agent run.
      def value_of(object, method)
        return nil unless object.respond_to?(method)

        object.public_send(method)
      rescue StandardError
        nil
      end

      def truthy?(value)
        value == true
      end

      def nil_or_empty?(value)
        value.nil? || value.to_s.empty?
      end
    end
  end
end
