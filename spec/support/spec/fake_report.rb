# frozen_string_literal: true

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
        evaluation_time: 2.0, changed: false, out_of_sync: false, line: 20
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
