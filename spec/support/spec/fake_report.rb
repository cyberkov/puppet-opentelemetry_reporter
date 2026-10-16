# frozen_string_literal: true

# Mirrors Puppet::Util::Metric: #values returns [id, label, value] triples.
class FakeMetric
  attr_reader :values

  def initialize(values)
    @values = values
  end
end

# A minimal stand-in for Puppet::Transaction::Report. Keeping it explicit makes
# the tests independent of the Puppet version's report internals, while the
# metrics themselves are asserted against a real in-memory exporter.
class FakeReport
  attr_reader :host, :environment, :status, :metrics, :cached_catalog_status, :transaction_completed

  def initialize(host: 'node1.example.com', environment: 'production',
                 status: 'changed', cached_catalog_status: 'not_used',
                 transaction_completed: true, metrics: nil)
    @host = host
    @environment = environment
    @status = status
    @cached_catalog_status = cached_catalog_status
    @transaction_completed = transaction_completed
    @metrics = metrics.nil? ? default_metrics : metrics
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
