# frozen_string_literal: true

module PuppetOtel
  # Translates a Puppet report into OpenTelemetry metrics.
  #
  # Metric names use the OpenTelemetry dot separator. The Prometheus exporter
  # in the OpenTelemetry Collector converts dots to underscores, so
  # puppet.report.resources is exposed to Prometheus as
  # puppet_report_resources, which is the series name the Prometheus report
  # processor produced. Existing dashboards therefore keep working.
  #
  # See docs/naming.md for the attribute decisions and their stability.
  class Metrics
    # Report metric categories and their OpenTelemetry unit.
    # "1" is the conventional unit for a dimensionless count.
    CATEGORIES = {
      'resources' => { name: 'puppet.report.resources', unit: '1',
                       description: 'Resources in the last Puppet run, broken down by state' },
      'time' => { name: 'puppet.report.time', unit: 's',
                  description: 'Time taken by the last Puppet run, broken down by resource type' },
      'changes' => { name: 'puppet.report.changes', unit: '1',
                     description: 'Changed resources in the last Puppet run' },
      'events' => { name: 'puppet.report.events', unit: '1',
                    description: 'Resource application events in the last Puppet run' },
    }.freeze

    RUN_STATUSES = %w[failed changed unchanged].freeze
    CACHED_CATALOG_STATUSES = %w[not_used explicitly_requested on_failure].freeze

    def initialize(meter, node_attribute: true)
      @meter = meter
      @node_attribute = node_attribute
      @instruments = {}
    end

    # Records every metric derived from one report.
    #
    # @param report [Puppet::Transaction::Report] or any object answering the
    #   same methods.
    def record(report)
      attributes = base_attributes(report)

      record_report_metrics(report, attributes)
      record_last_run(attributes)
      record_run_status(report, attributes)
      record_cached_catalog_status(report, attributes)
      record_transaction_completed(report, attributes)
      record_total_time(report, attributes)
    end

    private

    # Attributes common to every data point. The node is identified here and
    # not on the resource, because one server process reports for many nodes.
    def base_attributes(report)
      attributes = {}
      environment = value_of(report, :environment)
      attributes['deployment.environment.name'] = environment.to_s unless nil_or_empty?(environment)

      if @node_attribute
        host = value_of(report, :host)
        attributes['puppet.node.name'] = host.to_s unless nil_or_empty?(host)
      end

      attributes
    end

    def record_report_metrics(report, attributes)
      metrics = value_of(report, :metrics)
      return unless metrics.respond_to?(:each)

      CATEGORIES.each do |category, definition|
        data = metrics[category]
        next if data.nil?

        values = data.respond_to?(:values) ? data.values : nil
        next unless values.respond_to?(:each)

        gauge = gauge_for(definition)
        values.each do |entry|
          next unless entry.respond_to?(:[])

          # Entries are [machine_id, display_label, value]. The machine id is
          # used because attribute values must be bounded and machine readable.
          id = entry[0]
          value = entry[2]
          next if id.nil? || !value.is_a?(Numeric)

          gauge.record(value, attributes: attributes.merge('puppet.metric.name' => id.to_s))
        end
      end
    end

    def record_last_run(attributes)
      gauge = gauge_for(name: 'puppet.report.last_run.timestamp', unit: 's',
                        description: 'Unix timestamp of the last Puppet run')
      gauge.record(Time.now.to_i, attributes: attributes)
    end

    # Emitted as one data point per possible status, exactly one of which is 1.
    # This lets a query select on the status without the value itself being an
    # opaque enumeration, and mirrors the Prometheus reporter's puppet_status.
    def record_run_status(report, attributes)
      status = value_of(report, :status)
      return unless RUN_STATUSES.include?(status.to_s)

      gauge = gauge_for(name: 'puppet.run.status', unit: '1',
                        description: 'Status of the last Puppet run')
      RUN_STATUSES.each do |candidate|
        gauge.record(status.to_s == candidate ? 1 : 0,
                     attributes: attributes.merge('puppet.run.status' => candidate))
      end
    end

    def record_cached_catalog_status(report, attributes)
      status = value_of(report, :cached_catalog_status)
      return unless CACHED_CATALOG_STATUSES.include?(status.to_s)

      gauge = gauge_for(name: 'puppet.cached_catalog.status', unit: '1',
                        description: 'Whether a cached catalog was used, and why')
      CACHED_CATALOG_STATUSES.each do |candidate|
        gauge.record(status.to_s == candidate ? 1 : 0,
                     attributes: attributes.merge('puppet.cached_catalog_status' => candidate))
      end
    end

    def record_transaction_completed(report, attributes)
      completed = value_of(report, :transaction_completed)
      return unless [true, false].include?(completed)

      gauge = gauge_for(name: 'puppet.transaction.completed', unit: '1',
                        description: 'Whether the transaction of the last Puppet run completed')
      gauge.record(completed ? 1 : 0, attributes: attributes)
    end

    def record_total_time(report, attributes)
      duration = total_time_from_metrics(report)
      return unless duration.is_a?(Numeric)

      gauge = gauge_for(name: 'puppet.report.duration', unit: 's',
                        description: 'Total duration of the last Puppet run')
      gauge.record(duration, attributes: attributes)
    end

    def total_time_from_metrics(report)
      metrics = value_of(report, :metrics)
      return nil unless metrics.respond_to?(:[])

      time = metrics['time']
      return nil if time.nil? || !time.respond_to?(:values)

      entry = time.values.find { |e| e.respond_to?(:[]) && e[0].to_s == 'total' }
      entry && entry[2].is_a?(Numeric) ? entry[2] : nil
    end

    # Instruments are created once per meter and reused, because creating a
    # duplicate instrument of the same name is an error in the SDK.
    def gauge_for(definition)
      name = definition[:name]
      @instruments[name] ||= @meter.create_gauge(
        name,
        unit: definition[:unit],
        description: definition[:description],
      )
    end

    # Reads an attribute defensively. Report objects differ between Puppet
    # versions, and a missing method must never fail an agent run.
    def value_of(report, method)
      return nil unless report.respond_to?(method)

      report.public_send(method)
    rescue StandardError
      nil
    end

    def nil_or_empty?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
