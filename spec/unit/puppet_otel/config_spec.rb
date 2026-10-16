# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'puppet_otel/config'

describe PuppetOtel::Config do
  # Helper: write YAML to a temp file and yield a Config built from it.
  def with_config_file(content, env: {})
    file = Tempfile.new(['otel', '.yaml'])
    file.write(content)
    file.close
    yield described_class.new(path: file.path, env: env)
  ensure
    file&.unlink
  end

  describe 'precedence' do
    it 'prefers a file value over an environment variable' do
      with_config_file("service_name: from-file\n",
                       env: { 'OTEL_SERVICE_NAME' => 'from-env' }) do |config|
        expect(config.service_name).to eq('from-file')
      end
    end

    it 'falls back to the environment variable when the file omits the key' do
      with_config_file("enabled: true\n",
                       env: { 'OTEL_SERVICE_NAME' => 'from-env' }) do |config|
        expect(config.service_name).to eq('from-env')
      end
    end

    it 'falls back to the built-in default when neither is present' do
      config = described_class.new(path: nil, env: {})
      expect(config.service_name).to eq('openvox-server')
    end

    it 'ignores an empty environment variable and uses the default' do
      config = described_class.new(path: nil, env: { 'OTEL_SERVICE_NAME' => '' })
      expect(config.service_name).to eq('openvox-server')
    end
  end

  describe 'optional configuration file' do
    it 'operates on environment variables alone when no path is given' do
      config = described_class.new(path: nil, env: { 'OTEL_EXPORTER_OTLP_ENDPOINT' => 'http://collector:4318' })
      expect(config.endpoint).to eq('http://collector:4318')
    end

    it 'does not raise when the configured file is absent' do
      config = described_class.new(path: '/nonexistent/otel.yaml', env: {})
      expect(config.service_name).to eq('openvox-server')
    end

    it 'treats an empty file as no configuration' do
      with_config_file('') do |config|
        expect(config.enabled?).to be(true)
      end
    end

    it 'raises ConfigError on malformed YAML' do
      with_config_file("service_name: [unclosed\n") do |config|
        config
      end
    rescue PuppetOtel::Config::ConfigError => e
      expect(e.message).to match(/invalid YAML/)
    else
      raise 'expected ConfigError to be raised'
    end

    it 'raises ConfigError when the document is not a mapping' do
      expect do
        with_config_file("- a\n- b\n") { |c| c }
      end.to raise_error(PuppetOtel::Config::ConfigError, /expected a YAML mapping/)
    end
  end

  describe '#enabled? and signal toggles' do
    it 'is enabled by default' do
      expect(described_class.new(path: nil, env: {}).enabled?).to be(true)
    end

    it 'can be disabled in the file' do
      with_config_file("enabled: false\n") do |config|
        expect(config.enabled?).to be(false)
      end
    end

    it 'enables metrics by default' do
      expect(described_class.new(path: nil, env: {}).metrics_enabled?).to be(true)
    end

    it 'disables traces by default' do
      expect(described_class.new(path: nil, env: {}).traces_enabled?).to be(false)
    end

    it 'allows traces to be switched on' do
      with_config_file("traces:\n  enabled: true\n") do |config|
        expect(config.traces_enabled?).to be(true)
      end
    end

    it 'accepts string booleans' do
      with_config_file("enabled: 'no'\n") do |config|
        expect(config.enabled?).to be(false)
      end
    end
  end

  describe '#timeout' do
    it 'defaults to 10 seconds' do
      expect(described_class.new(path: nil, env: {}).timeout).to eq(10.0)
    end

    it 'reads seconds from the file' do
      with_config_file("timeout: 2.5\n") do |config|
        expect(config.timeout).to eq(2.5)
      end
    end

    it 'converts the environment variable from milliseconds to seconds' do
      config = described_class.new(path: nil, env: { 'OTEL_EXPORTER_OTLP_TIMEOUT' => '5000' })
      expect(config.timeout).to eq(5.0)
    end
  end

  describe '#resource_attributes' do
    it 'parses OTEL_RESOURCE_ATTRIBUTES' do
      config = described_class.new(
        path: nil,
        env: { 'OTEL_RESOURCE_ATTRIBUTES' => 'deployment.environment.name=prod,service.version=1.2.3' },
      )
      expect(config.resource_attributes).to eq(
        'deployment.environment.name' => 'prod',
        'service.version' => '1.2.3',
      )
    end

    it 'merges file attributes over environment attributes' do
      with_config_file("resource_attributes:\n  service.version: '9.9.9'\n",
                       env: { 'OTEL_RESOURCE_ATTRIBUTES' => 'service.version=1.2.3,host.arch=arm64' }) do |config|
        expect(config.resource_attributes).to eq(
          'service.version' => '9.9.9',
          'host.arch' => 'arm64',
        )
      end
    end

    it 'ignores malformed entries' do
      config = described_class.new(path: nil, env: { 'OTEL_RESOURCE_ATTRIBUTES' => 'good=1,,broken,=2' })
      expect(config.resource_attributes).to eq('good' => '1')
    end

    it 'returns an empty hash when unset' do
      expect(described_class.new(path: nil, env: {}).resource_attributes).to eq({})
    end
  end

  describe '#environments and #report_environment?' do
    it 'reports on every environment when no allowlist is set' do
      config = described_class.new(path: nil, env: {})
      expect(config.report_environment?('production')).to be(true)
    end

    it 'honours an allowlist' do
      with_config_file("environments:\n  - production\n") do |config|
        expect(config.report_environment?('production')).to be(true)
        expect(config.report_environment?('development')).to be(false)
      end
    end
  end

  describe '.from_confdir' do
    it 'looks for otel.yaml inside the confdir' do
      config = described_class.from_confdir('/etc/puppetlabs/puppet', env: {})
      expect(config.path).to eq('/etc/puppetlabs/puppet/otel.yaml')
    end
  end
end
