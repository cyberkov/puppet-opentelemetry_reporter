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

  # A real tracer, but backed by an in-memory exporter, for the same reason as
  # the meter above.
  let(:in_memory_tracer) do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
        OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new,
      ),
    )
    provider.tracer('test')
  end

  before do
    require 'puppet/reports/opentelemetry'
    PuppetX::OpentelemetryReporter::SDK.reset!
    allow(Puppet.settings).to receive(:[]).with(:config).and_return(File.join(confdir, 'puppet.conf'))
    allow(PuppetX::OpentelemetryReporter::SDK).to receive_messages(meter: in_memory_meter, tracer: in_memory_tracer)
    allow(PuppetX::OpentelemetryReporter::SDK).to receive(:force_flush)
  end

  after do
    PuppetX::OpentelemetryReporter::SDK.reset!
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
    expect(processor.doc).to match(%r{OpenTelemetry})
  end

  it 'records metrics and flushes them' do
    write_config("endpoint: http://localhost:4318\n")
    report_for.process
    expect(PuppetX::OpentelemetryReporter::SDK).to have_received(:force_flush)
  end

  it 'does not register instruments again for later reports' do
    write_config("endpoint: http://localhost:4318\n")
    allow(in_memory_meter).to receive(:create_gauge).and_call_original

    2.times { report_for.process }

    expect(in_memory_meter).to have_received(:create_gauge).exactly(9).times
  end

  it 'does nothing when disabled' do
    write_config("enabled: false\n")
    report_for.process
    expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:meter)
  end

  it 'does nothing when metrics are disabled' do
    write_config("metrics:\n  enabled: false\n")
    report_for.process
    expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:meter)
  end

  it 'skips environments outside the allowlist' do
    write_config("environments:\n  - production\n")
    report_for(environment: 'development').process
    expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:meter)
  end

  it 'processes environments inside the allowlist' do
    write_config("environments:\n  - production\n")
    allow(PuppetX::OpentelemetryReporter::SDK).to receive(:meter).and_return(nil)
    report_for(environment: 'production').process
    expect(PuppetX::OpentelemetryReporter::SDK).to have_received(:meter)
  end

  it 'does not raise when the configuration file is absent' do
    expect { report_for.process }.not_to raise_error
  end

  it 'logs and does not raise when the SDK fails' do
    allow(PuppetX::OpentelemetryReporter::SDK).to receive(:meter).and_raise(StandardError, 'boom')
    allow(Puppet).to receive(:err)
    expect { report_for.process }.not_to raise_error
    expect(Puppet).to have_received(:err).with(%r{could not process report})
  end

  it 'does not raise when the configuration file is malformed' do
    write_config("broken: [unclosed\n")
    allow(Puppet).to receive(:err)
    expect { report_for.process }.not_to raise_error
    expect(Puppet).to have_received(:err).with(%r{could not process report})
  end

  describe 'traces' do
    it 'does not record traces unless they are switched on' do
      write_config("endpoint: http://localhost:4318\n")
      report_for.process
      expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:tracer)
    end

    it 'records traces when they are switched on' do
      write_config("traces:\n  enabled: true\n")
      report_for.process
      expect(PuppetX::OpentelemetryReporter::SDK).to have_received(:tracer)
    end

    # Regression test: the metrics guard used to return early, which made
    # traces unreachable whenever metrics were switched off.
    it 'records traces even when metrics are disabled' do
      write_config("metrics:\n  enabled: false\ntraces:\n  enabled: true\n")
      report_for.process

      expect(PuppetX::OpentelemetryReporter::SDK).to have_received(:tracer)
      expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:meter)
    end

    it 'does not flush when neither signal is enabled' do
      write_config("metrics:\n  enabled: false\n")
      report_for.process
      expect(PuppetX::OpentelemetryReporter::SDK).not_to have_received(:force_flush)
    end
  end
end
