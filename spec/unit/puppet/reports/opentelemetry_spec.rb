# frozen_string_literal: true

require 'spec_helper'
require 'puppet'
require 'puppet/reports'
require 'tempfile'
require 'fileutils'
require 'opentelemetry/sdk'
require 'opentelemetry-metrics-sdk'

describe 'opentelemetry report processor' do
  let(:confdir) { Dir.mktmpdir('otel-conf') }
  let(:processor) { Puppet::Reports.report(:opentelemetry) }

  # A real meter, but backed by an in-memory reader. Without this the examples
  # build a genuine OTLP exporter and block on network retries.
  let(:in_memory_meter) do
    provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    provider.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new)
    provider.meter('test')
  end

  before do
    require 'puppet/reports/opentelemetry'
    PuppetOtel::SDK.reset!
    allow(Puppet.settings).to receive(:[]).with(:config).and_return(File.join(confdir, 'puppet.conf'))
    allow(PuppetOtel::SDK).to receive(:meter).and_return(in_memory_meter)
    allow(PuppetOtel::SDK).to receive(:force_flush)
  end

  after do
    PuppetOtel::SDK.reset!
    FileUtils.remove_entry(confdir)
  end

  # Builds a report object extended with the processor, as Puppet does.
  def report_for(status: 'changed', environment: 'production')
    report = FakeReport.new(status: status, environment: environment)
    report.extend(processor)
    report
  end

  def write_config(content)
    File.write(File.join(confdir, 'otel.yaml'), content)
  end

  it 'is registered under the :opentelemetry name' do
    expect(processor).not_to be_nil
  end

  it 'documents itself' do
    expect(processor.doc).to match(/OpenTelemetry/)
  end

  it 'records metrics and flushes them' do
    write_config("endpoint: http://localhost:4318\n")
    expect(PuppetOtel::SDK).to receive(:force_flush)
    report_for.process
  end

  it 'does nothing when disabled' do
    write_config("enabled: false\n")
    expect(PuppetOtel::SDK).not_to receive(:meter)
    report_for.process
  end

  it 'does nothing when metrics are disabled' do
    write_config("metrics:\n  enabled: false\n")
    expect(PuppetOtel::SDK).not_to receive(:meter)
    report_for.process
  end

  it 'skips environments outside the allowlist' do
    write_config("environments:\n  - production\n")
    expect(PuppetOtel::SDK).not_to receive(:meter)
    report_for(environment: 'development').process
  end

  it 'processes environments inside the allowlist' do
    write_config("environments:\n  - production\n")
    expect(PuppetOtel::SDK).to receive(:meter).and_return(nil)
    report_for(environment: 'production').process
  end

  it 'does not raise when the configuration file is absent' do
    expect { report_for.process }.not_to raise_error
  end

  it 'logs and does not raise when the SDK fails' do
    allow(PuppetOtel::SDK).to receive(:meter).and_raise(StandardError, 'boom')
    expect(Puppet).to receive(:err).with(/could not process report/)
    expect { report_for.process }.not_to raise_error
  end

  it 'does not raise when the configuration file is malformed' do
    write_config("broken: [unclosed\n")
    expect(Puppet).to receive(:err).with(/could not process report/)
    expect { report_for.process }.not_to raise_error
  end
end
