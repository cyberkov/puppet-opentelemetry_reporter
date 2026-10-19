# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

describe 'opentelemetry_reporter' do
  let(:otel_path) { '/etc/puppetlabs/puppet/otel.yaml' }
  let(:rendered) { YAML.safe_load(catalogue.resource('File', otel_path)[:content]) }
  let(:params) { {} }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with defaults' do
        it { is_expected.to compile.with_all_deps }

        it do
          is_expected.to contain_file(otel_path).with(
            ensure: 'present', owner: 'root', group: 'puppet', mode: '0640',
          )
        end

        it 'renders only enabled' do
          expect(rendered).to eq('enabled' => true)
        end

        it { is_expected.to have_package_resource_count(0) }
      end

      context 'with enabled => false' do
        let(:params) { { enabled: false } }

        it { is_expected.to compile.with_all_deps }

        it 'keeps the false value' do
          expect(rendered).to eq('enabled' => false)
        end
      end

      context 'with a full parameter set' do
        let(:params) do
          {
            endpoint: 'http://collector.example.com:4318',
            service_name: 'puppetserver',
            timeout: 5,
            export_interval: 30,
            resource_attributes: { 'deployment.environment' => 'prod' },
            headers: { 'Authorization' => 'Bearer a: b' },
            environments: %w[production staging],
            metrics_enabled: true,
            metrics_node_attribute: false,
            traces_enabled: true,
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'renders every key, quoting header values correctly' do
          expect(rendered).to eq(
            'enabled' => true,
            'endpoint' => 'http://collector.example.com:4318',
            'service_name' => 'puppetserver',
            'timeout' => 5,
            'export_interval' => 30,
            'resource_attributes' => { 'deployment.environment' => 'prod' },
            'headers' => { 'Authorization' => 'Bearer a: b' },
            'environments' => %w[production staging],
            'metrics' => { 'enabled' => true, 'node_attribute' => false },
            'traces' => { 'enabled' => true },
          )
        end
      end

      context 'with only one metrics key set' do
        let(:params) { { metrics_node_attribute: false } }

        it 'omits the unset sibling key' do
          expect(rendered['metrics']).to eq('node_attribute' => false)
          expect(rendered).not_to have_key('traces')
        end
      end

      context 'without headers' do
        it 'omits the key so OTEL_EXPORTER_OTLP_HEADERS still applies' do
          expect(rendered).not_to have_key('headers')
        end
      end

      context 'with a custom confdir and file settings' do
        let(:params) { { confdir: '/opt/puppet', owner: 'puppet', group: 'puppet', mode: '0600' } }

        it do
          is_expected.to contain_file('/opt/puppet/otel.yaml').with(owner: 'puppet', group: 'puppet', mode: '0600')
        end
      end

      context 'with ensure => absent' do
        let(:params) { { ensure: 'absent' } }

        it { is_expected.to contain_file(otel_path).with_ensure('absent') }
      end

      context 'with manage_gems => true' do
        let(:params) { { manage_gems: true } }

        %w[opentelemetry-sdk opentelemetry-metrics-sdk opentelemetry-exporter-otlp-metrics].each do |gem|
          it { is_expected.to contain_package(gem).with(ensure: 'installed', provider: 'puppetserver_gem') }
        end

        it { is_expected.not_to contain_package('opentelemetry-exporter-otlp') }
      end

      context 'with manage_gems and traces_enabled' do
        let(:params) { { manage_gems: true, traces_enabled: true } }

        it { is_expected.to contain_package('opentelemetry-exporter-otlp').with_provider('puppetserver_gem') }
        it { is_expected.to have_package_resource_count(4) }
      end
    end
  end
end
