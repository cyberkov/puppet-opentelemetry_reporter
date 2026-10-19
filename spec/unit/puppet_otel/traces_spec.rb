# frozen_string_literal: true

require 'spec_helper'
require 'opentelemetry/sdk'
require 'puppet_otel/traces'

# FakeReport, FakeMetric and FakeResourceStatus are defined in
# spec/support/spec/fake_report.rb.

describe PuppetOtel::Traces do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:tracer) { provider.tracer('test') }

  before do
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter),
    )
  end

  def record(report = FakeReport.new, node_attribute: true)
    described_class.new(tracer, node_attribute: node_attribute).record(report)
    exporter.finished_spans
  end

  def root_span(spans)
    spans.find { |s| s.name == described_class::ROOT_SPAN_NAME }
  end

  describe 'the run span' do
    it 'emits a root span for the run' do
      expect(root_span(record)).not_to be_nil
    end

    it 'describes the run on the root span' do
      attributes = root_span(record).attributes

      expect(attributes['puppet.node.name']).to eq('node1.example.com')
      expect(attributes['deployment.environment.name']).to eq('production')
      expect(attributes['puppet.run.status']).to eq('changed')
      expect(attributes['puppet.cached_catalog_status']).to eq('not_used')
    end

    it 'omits the node name when the node attribute is disabled' do
      attributes = root_span(record(FakeReport.new, node_attribute: false)).attributes

      expect(attributes).not_to have_key('puppet.node.name')
    end

    # The report arrives after the run, so the span must be back dated rather
    # than recorded at the time of export.
    it 'back dates the span to the time of the run' do
      started = Time.utc(2024, 1, 1, 10, 0, 0)
      span = root_span(record(FakeReport.new(time: started)))

      expect(Time.at(span.start_timestamp / 1_000_000_000.0).utc).to be_within(1).of(started)
    end

    # 12.5 is the "total" entry of the time metric in FakeReport.
    it 'spans the duration reported by the run rather than wall clock time' do
      span = root_span(record)
      duration = (span.end_timestamp - span.start_timestamp) / 1_000_000_000.0

      expect(duration).to be_within(0.01).of(12.5)
    end

    it 'marks a failed run as an error' do
      span = root_span(record(FakeReport.new(status: 'failed')))

      expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end

    it 'leaves a successful run unset' do
      expect(root_span(record).status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  describe 'resource spans' do
    it 'emits a child span per evaluated resource' do
      names = record.map(&:name)

      expect(names).to include('File[/tmp/example]', 'Package[vim]')
    end

    it 'parents the resource spans to the run' do
      spans = record
      root = root_span(spans)
      child = spans.find { |s| s.name == 'File[/tmp/example]' }

      expect(child.parent_span_id).to eq(root.span_id)
      expect(child.trace_id).to eq(root.trace_id)
    end

    it 'describes the resource and where it was declared' do
      attributes = record.find { |s| s.name == 'File[/tmp/example]' }.attributes

      expect(attributes['puppet.resource.type']).to eq('File')
      expect(attributes['puppet.resource.title']).to eq('/tmp/example')
      expect(attributes['puppet.resource.changed']).to be(true)
      expect(attributes['code.file.path']).to eq('/etc/puppetlabs/code/site.pp')
      expect(attributes['code.line.number']).to eq(12)
    end

    it 'uses the evaluation time as the span duration' do
      span = record.find { |s| s.name == 'Package[vim]' }
      duration = (span.end_timestamp - span.start_timestamp) / 1_000_000_000.0

      expect(duration).to be_within(0.01).of(2.0)
    end

    it 'marks a failed resource as an error' do
      statuses = { 'File[/tmp/boom]' => FakeResourceStatus.new(resource: 'File[/tmp/boom]', failed: true) }
      span = record(FakeReport.new(resource_statuses: statuses)).find { |s| s.name == 'File[/tmp/boom]' }

      expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    end

    # A skipped resource was never evaluated, so it has no duration to show.
    it 'does not emit a span for a skipped resource' do
      statuses = { 'File[/tmp/skip]' => FakeResourceStatus.new(resource: 'File[/tmp/skip]', skipped: true) }
      names = record(FakeReport.new(resource_statuses: statuses)).map(&:name)

      expect(names).not_to include('File[/tmp/skip]')
    end
  end

  describe 'robustness' do
    # A telemetry failure must never fail an agent run.
    it 'still emits the run span when a resource status is unusable' do
      statuses = { 'Broken' => Object.new }
      spans = record(FakeReport.new(resource_statuses: statuses))

      expect(root_span(spans)).not_to be_nil
    end

    it 'tolerates a report without resource statuses' do
      spans = record(FakeReport.new(resource_statuses: {}))

      expect(spans.map(&:name)).to eq([described_class::ROOT_SPAN_NAME])
    end
  end
end
