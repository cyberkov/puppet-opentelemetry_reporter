# frozen_string_literal: true

# Mirrors Puppet::Util::Metric: #values returns [id, label, value] triples.
class FakeMetric
  attr_reader :values

  def initialize(values)
    @values = values
  end
end

# A minimal stand-in for Puppet::Resource::Status, which the trace mapping
# reads one span per entry from.
class FakeResourceStatus
  attr_reader :resource, :resource_type, :title, :evaluation_time, :file, :line, :time,
              :changed, :out_of_sync, :failed, :skipped

  def initialize(resource: 'File[/tmp/example]', resource_type: 'File', title: '/tmp/example',
                 evaluation_time: 0.5, changed: true, out_of_sync: true, failed: false,
                 skipped: false, file: '/etc/puppetlabs/code/site.pp', line: 12, time: nil)
    @resource = resource
    @resource_type = resource_type
    @title = title
    @evaluation_time = evaluation_time
    @changed = changed
    @out_of_sync = out_of_sync
    @failed = failed
    @skipped = skipped
    @file = file
    @line = line
    @time = time
  end
end

# A minimal stand-in for Puppet::Transaction::Report. Keeping it explicit makes
# the tests independent of the Puppet version's report internals, while the
# metrics themselves are asserted against a real in-memory exporter.
class FakeReport
  attr_reader :host, :environment, :status, :metrics, :cached_catalog_status, :transaction_completed,
              :time, :transaction_uuid, :resource_statuses

  def initialize(host: 'node1.example.com', environment: 'production',
                 status: 'changed', cached_catalog_status: 'not_used',
                 transaction_completed: true, metrics: nil,
                 time: Time.utc(2024, 1, 1, 10, 0, 0),
                 transaction_uuid: 'a1b2c3d4-0000-0000-0000-000000000000',
                 resource_statuses: nil)
    @host = host
    @environment = environment
    @status = status
    @cached_catalog_status = cached_catalog_status
    @transaction_completed = transaction_completed
    @metrics = metrics.nil? ? default_metrics : metrics
    @time = time
    @transaction_uuid = transaction_uuid
    @resource_statuses = resource_statuses.nil? ? default_resource_statuses : resource_statuses
  end

  # Keyed by resource title, as Puppet::Transaction::Report does.
  def default_resource_statuses
    {
      'File[/tmp/example]' => FakeResourceStatus.new,
      'Package[vim]' => FakeResourceStatus.new(
        resource: 'Package[vim]', resource_type: 'Package', title: 'vim',
        evaluation_time: 2.0, changed: false, out_of_sync: false, line: 20,
      ),
    }
  end

  def default_metrics
    {
      'resources' => FakeMetric.new([['total', 'Total', 42], ['changed', 'Changed', 3]]),
      'time' => FakeMetric.new([['total', 'Total', 12.5], ['file', 'File', 1.25]]),
      'changes' => FakeMetric.new([['total', 'Total', 3]]),
      'events' => FakeMetric.new([['total', 'Total', 3], ['success', 'Success', 3]]),
    }
  end
end
