# frozen_string_literal: true

require 'yaml'

module PuppetOtel
  # Configuration for the OpenTelemetry report processor.
  #
  # Values are resolved with the following precedence, highest first:
  #
  #   1. an explicit key in the YAML configuration file (otel.yaml)
  #   2. the standard OpenTelemetry environment variable (OTEL_*)
  #   3. a built-in default
  #
  # The YAML file is optional. When it is absent the processor is configured
  # entirely from the standard OpenTelemetry environment variables, which is a
  # supported mode of operation. A file that exists but cannot be parsed is an
  # error, because that is a misconfiguration rather than an absence of one.
  class Config
    DEFAULT_FILENAME = 'otel.yaml'
    DEFAULT_SERVICE_NAME = 'openvox-server'
    DEFAULT_ENDPOINT = 'http://localhost:4318'
    DEFAULT_TIMEOUT = 10
    DEFAULT_EXPORT_INTERVAL = 30

    # Raised when the configuration file exists but is not usable.
    class ConfigError < StandardError; end

    attr_reader :path, :data

    # @param path [String, nil] path to otel.yaml. When nil, no file is read.
    # @param env [Hash] environment to read OTEL_* variables from.
    def initialize(path: nil, env: ENV)
      @path = path
      @env = env
      @data = load_file(path)
    end

    # Builds a Config from the Puppet confdir, i.e. the directory holding
    # puppet.conf. Mirrors how other report processors locate their settings.
    #
    # @param confdir [String] directory containing puppet.conf
    def self.from_confdir(confdir, env: ENV)
      new(path: File.join(confdir, DEFAULT_FILENAME), env: env)
    end

    # Whether to attach the reported node name to every data point. Disabling
    # this aggregates all nodes together, which bounds cardinality on large
    # installations at the cost of per-node detail.
    def node_attribute?
      section_bool('metrics', 'node_attribute', true)
    end

    # How often the periodic reader exports, in seconds.
    def export_interval
      value = @data['export_interval']
      return Float(value) unless value.nil?

      Float(DEFAULT_EXPORT_INTERVAL)
    end

    def enabled?
      fetch_bool('enabled', nil, true)
    end

    def metrics_enabled?
      section_bool('metrics', 'enabled', true)
    end

    # Traces are opt-in. A catalog with thousands of resources produces a span
    # per resource, so this must be a deliberate choice.
    def traces_enabled?
      section_bool('traces', 'enabled', false)
    end

    def service_name
      fetch_string('service_name', 'OTEL_SERVICE_NAME', DEFAULT_SERVICE_NAME)
    end

    def endpoint
      fetch_string('endpoint', 'OTEL_EXPORTER_OTLP_ENDPOINT', DEFAULT_ENDPOINT)
    end

    def timeout
      value = @data['timeout']
      return Float(value) unless value.nil?

      env_value = @env['OTEL_EXPORTER_OTLP_TIMEOUT']
      # The OTel environment variable is specified in milliseconds.
      return Float(env_value) / 1000.0 unless nil_or_empty?(env_value)

      Float(DEFAULT_TIMEOUT)
    end

    # Resource attributes from OTEL_RESOURCE_ATTRIBUTES merged with any
    # declared in the file. File entries win on conflict, consistent with the
    # documented precedence.
    def resource_attributes
      merged = parse_otel_resource_attributes(@env['OTEL_RESOURCE_ATTRIBUTES'])
      from_file = @data['resource_attributes']
      from_file.each { |k, v| merged[k.to_s] = v.to_s } if from_file.is_a?(Hash)
      merged
    end

    def headers
      from_file = @data['headers']
      return stringify(from_file) if from_file.is_a?(Hash)

      parse_otel_resource_attributes(@env['OTEL_EXPORTER_OTLP_HEADERS'])
    end

    # Optional allowlist of Puppet environments to report on. An empty list
    # means "report on every environment".
    def environments
      value = @data['environments']
      return [] unless value.is_a?(Array)

      value.map(&:to_s)
    end

    def report_environment?(environment)
      allowed = environments
      allowed.empty? || allowed.include?(environment.to_s)
    end

    private

    def load_file(path)
      return {} if path.nil? || !File.exist?(path)

      loaded = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
      return {} if loaded.nil? || loaded == false

      raise ConfigError, "#{path}: expected a YAML mapping, got #{loaded.class}" unless loaded.is_a?(Hash)

      loaded
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{path}: invalid YAML: #{e.message}"
    end

    def fetch_string(key, env_key, default)
      value = @data[key]
      return value.to_s unless nil_or_empty?(value)

      env_value = env_key && @env[env_key]
      return env_value.to_s unless nil_or_empty?(env_value)

      default
    end

    def fetch_bool(key, env_key, default)
      value = @data[key]
      return truthy?(value) unless value.nil?

      env_value = env_key && @env[env_key]
      return truthy?(env_value) unless nil_or_empty?(env_value)

      default
    end

    def section_bool(section, key, default)
      sub = @data[section]
      return default unless sub.is_a?(Hash)
      return default if sub[key].nil?

      truthy?(sub[key])
    end

    def truthy?(value)
      return value if [true, false].include?(value)

      %w[1 true yes on].include?(value.to_s.strip.downcase)
    end

    def nil_or_empty?(value)
      value.nil? || value.to_s.empty?
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
    end

    # Parses the W3C Baggage style list used by OTEL_RESOURCE_ATTRIBUTES and
    # OTEL_EXPORTER_OTLP_HEADERS, e.g. "key1=value1,key2=value2".
    def parse_otel_resource_attributes(raw)
      return {} if nil_or_empty?(raw)

      raw.split(',').each_with_object({}) do |pair, acc|
        key, value = pair.split('=', 2)
        next if key.nil? || value.nil?

        key = key.strip
        next if key.empty?

        acc[key] = value.strip
      end
    end
  end
end
