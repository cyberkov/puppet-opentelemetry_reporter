# frozen_string_literal: true

require 'spec_helper'
require 'opentelemetry/sdk'
require 'opentelemetry-metrics-sdk'
require 'puppet_otel/metrics'

# FakeReport and FakeMetric are defined in spec/support/spec/fake_report.rb.

describe PuppetOtel::Metrics do
  let(:exporter) { OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new }
  let(:provider) { OpenTelemetry::SDK::Metrics::MeterProvider.new }
  let(:meter) { provider.meter('test') }

  before { provider.add_metric_reader(exporter) }

  # Collects emitted data points as {metric_name => [{attributes, value}, ...]}
  def emitted
    exporter.pull
    exporter.metric_snapshots.flatten.each_with_object({}) do |snapshot, acc|
      acc[snapshot.name] ||= []
      snapshot.data_points.each do |point|
        acc[snapshot.name] << { attributes: point.attributes, value: point.value }
      end
    end
  end

  def record(report = FakeReport.new, node_attribute: true)
    described_class.new(meter, node_attribute: node_attribute).record(report)
    emitted
  end

  describe 'metric names' do
    it 'uses OpenTelemetry dotted names that translate to the Prometheus series' do
      expect(record.keys).to include(
        'puppet.report.resources',
        'puppet.report.time',
        'puppet.report.changes',
        'puppet.report.events',
        'puppet.report.last_run.timestamp',
        'puppet.run.status',
        'puppet.cached_catalog.status',
        'puppet.transaction.completed',
        'puppet.report.duration',
      )
    end
  end

  describe 'report metrics' do
    it 'records each category value with its machine readable id' do
      total = record['puppet.report.resources'].find { |p| p[:attributes]['puppet.metric.name'] == 'total' }
      expect(total[:value]).to eq(42)
    end

    it 'uses the machine id rather than the display label' do
      names = record['puppet.report.resources'].map { |p| p[:attributes]['puppet.metric.name'] }
      expect(names).to include('changed')
      expect(names).not_to include('Changed')
    end

    it 'records floating point times' do
      file = record['puppet.report.time'].find { |p| p[:attributes]['puppet.metric.name'] == 'file' }
      expect(file[:value]).to be_within(0.001).of(1.25)
    end
  end

  describe 'attributes' do
    it 'identifies the reported node on the data point' do
      point = record['puppet.report.duration'].first
      expect(point[:attributes]['puppet.node.name']).to eq('node1.example.com')
    end

    it 'uses the stable deployment.environment.name key' do
      point = record['puppet.report.duration'].first
      expect(point[:attributes]['deployment.environment.name']).to eq('production')
    end

    it 'omits the node name when node_attribute is disabled' do
      point = record(FakeReport.new, node_attribute: false)['puppet.report.duration'].first
      expect(point[:attributes]).not_to have_key('puppet.node.name')
      expect(point[:attributes]['deployment.environment.name']).to eq('production')
    end
  end

  describe 'run status' do
    it 'emits one series per status with exactly one set to 1' do
      points = record(FakeReport.new(status: 'failed'))['puppet.run.status']
      by_status = points.to_h { |p| [p[:attributes]['puppet.run.status'], p[:value]] }
      expect(by_status).to eq('failed' => 1, 'changed' => 0, 'unchanged' => 0)
    end

    it 'ignores an unknown status' do
      expect(record(FakeReport.new(status: 'bogus'))).not_to have_key('puppet.run.status')
    end
  end

  describe 'cached catalog status' do
    it 'emits one series per known status' do
      points = record(FakeReport.new(cached_catalog_status: 'on_failure'))['puppet.cached_catalog.status']
      by_status = points.to_h { |p| [p[:attributes]['puppet.cached_catalog_status'], p[:value]] }
      expect(by_status).to eq('not_used' => 0, 'explicitly_requested' => 0, 'on_failure' => 1)
    end
  end

  describe 'transaction completed' do
    it 'records 0 when the transaction did not complete' do
      points = record(FakeReport.new(transaction_completed: false))['puppet.transaction.completed']
      expect(points.first[:value]).to eq(0)
    end
  end

  describe 'duration' do
    it 'takes the total entry from the time category' do
      expect(record['puppet.report.duration'].first[:value]).to be_within(0.001).of(12.5)
    end
  end

  describe 'robustness' do
    it 'does not raise when the report has no metrics' do
      expect { described_class.new(meter).record(FakeReport.new(metrics: {})) }.not_to raise_error
    end

    it 'skips non numeric values' do
      report = FakeReport.new(metrics: { 'resources' => FakeMetric.new([['total', 'Total', nil]]) })
      expect { described_class.new(meter).record(report) }.not_to raise_error
    end

    it 'does not raise when the report omits optional fields' do
      bare = Struct.new(:host, :environment).new('n1', 'production')
      expect { described_class.new(meter).record(bare) }.not_to raise_error
    end
  end
end
