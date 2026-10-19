source ENV['GEM_SOURCE'] || 'https://rubygems.org'

group :test do
  gem 'voxpupuli-test', '~> 14.0', require: false
  gem 'puppet_metadata', '~> 6.4', require: false
end

group :development do
  gem 'guard-rake', require: false
  gem 'overcommit', '>= 0.39.1', require: false
end

group :system_tests do
  gem 'voxpupuli-acceptance', '~> 4.4', require: false
end

group :release do
  gem 'voxpupuli-release', '~> 5.5', require: false
end

gem 'rake', require: false

gem 'openvox', ENV.fetch('OPENVOX_GEM_VERSION', ['>= 8', '< 10']), require: false, groups: [:test]

# OpenTelemetry runtime dependencies.
#
# Tracing gems are stable 1.x. The metrics gems are EXPERIMENTAL 0.x and are
# versioned independently from the tracing SDK -- deliberately left unpinned
# beyond a major-zero floor so Bundler resolves them on their own release
# cadence. Review Gemfile.lock and each changelog when these move.
gem 'opentelemetry-sdk', '~> 1.0', require: false
gem 'opentelemetry-exporter-otlp', '~> 0.30', require: false
gem 'opentelemetry-metrics-api', require: false
gem 'opentelemetry-metrics-sdk', require: false
gem 'opentelemetry-exporter-otlp-metrics', require: false

# vim: syntax=ruby
