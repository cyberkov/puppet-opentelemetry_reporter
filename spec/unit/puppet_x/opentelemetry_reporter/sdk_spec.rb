# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/opentelemetry_reporter/sdk'

describe PuppetX::OpentelemetryReporter::SDK do
  let(:config) { PuppetX::OpentelemetryReporter::Config.new(path: nil, env: {}) }

  before { described_class.reset! }
  after { described_class.reset! }

  describe '.meter' do
    it 'returns a usable meter' do
      expect(described_class.meter(config)).to respond_to(:create_counter)
    end

    it 'builds the provider only once' do
      first = described_class.meter(config)
      second = described_class.meter(config)
      expect(second).to be(first)
    end

    it 'marks itself configured' do
      described_class.meter(config)
      expect(described_class).to be_configured
    end
  end

  describe '.metrics' do
    let(:meter) { described_class.meter(config) }

    it 'returns the same recorder for the same meter' do
      first = described_class.metrics(meter)
      second = described_class.metrics(meter)
      expect(second).to be(first)
    end

    it 'returns a different recorder when node_attribute differs' do
      expect(described_class.metrics(meter, node_attribute: false))
        .not_to be(described_class.metrics(meter, node_attribute: true))
    end

    it 'returns a new recorder after reset!' do
      first = described_class.metrics(meter)
      described_class.reset!
      expect(described_class.metrics(described_class.meter(config))).not_to be(first)
    end
  end

  describe 'resource' do
    it 'describes the server, not the reported node' do
      described_class.meter(config)
      attrs = described_class.send(:resource, config).attribute_enumerator.to_h
      expect(attrs['service.name']).to eq('openvox-server')
      expect(attrs).to have_key('host.name')
      expect(attrs).not_to have_key('puppet.node.name')
    end

    it 'merges configured resource attributes' do
      env = { 'OTEL_RESOURCE_ATTRIBUTES' => 'service.namespace=puppet' }
      cfg = PuppetX::OpentelemetryReporter::Config.new(path: nil, env: env)
      attrs = described_class.send(:resource, cfg).attribute_enumerator.to_h
      expect(attrs['service.namespace']).to eq('puppet')
    end
  end

  describe 'endpoint handling' do
    it 'appends the metrics signal path to a base endpoint' do
      expect(described_class.send(:metrics_endpoint, config)).to eq('http://localhost:4318/v1/metrics')
    end

    it 'does not append the path twice' do
      cfg = PuppetX::OpentelemetryReporter::Config.new(path: nil, env: { 'OTEL_EXPORTER_OTLP_ENDPOINT' => 'http://c:4318/v1/metrics' })
      expect(described_class.send(:metrics_endpoint, cfg)).to eq('http://c:4318/v1/metrics')
    end

    it 'strips a trailing slash' do
      cfg = PuppetX::OpentelemetryReporter::Config.new(path: nil, env: { 'OTEL_EXPORTER_OTLP_ENDPOINT' => 'http://c:4318/' })
      expect(described_class.send(:metrics_endpoint, cfg)).to eq('http://c:4318/v1/metrics')
    end
  end

  describe 'failure handling' do
    it 'returns nil and does not raise when the provider cannot be built' do
      allow(described_class).to receive(:build_meter_provider).and_return(nil)
      expect { described_class.meter(config) }.not_to raise_error
      expect(described_class.meter(config)).to be_nil
    end

    it 'does not raise when flushing without a provider' do
      expect { described_class.force_flush }.not_to raise_error
    end

    it 'does not raise when a flush fails' do
      described_class.meter(config)
      provider = described_class.instance_variable_get(:@meter_provider)
      allow(provider).to receive(:force_flush).and_raise(StandardError, 'boom')
      expect { described_class.force_flush }.not_to raise_error
    end

    it 'does not raise when shutdown fails' do
      described_class.meter(config)
      provider = described_class.instance_variable_get(:@meter_provider)
      allow(provider).to receive(:shutdown).and_raise(StandardError, 'boom')
      expect { described_class.shutdown }.not_to raise_error
    end
  end

  describe '.reset!' do
    it 'clears the configured provider' do
      described_class.meter(config)
      described_class.reset!
      expect(described_class).not_to be_configured
    end
  end
end
