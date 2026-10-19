# frozen_string_literal: true

require 'spec_helper'
require 'open3'

# The generated file is the artefact operators actually install, so it is
# verified as a file loaded by a separate Ruby process rather than through the
# module's own load path.
describe 'dist/opentelemetry.rb' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:dist) { File.join(root, 'dist', 'opentelemetry.rb') }

  # Building once is far cheaper than per example, so the hook is kept.
  # rubocop:disable RSpec/BeforeAfterAll
  before(:all) do
    Dir.chdir(File.expand_path('../..', __dir__)) do
      system('bundle exec rake dist:build', out: File::NULL, err: File::NULL)
    end
  end
  # rubocop:enable RSpec/BeforeAfterAll

  it 'is generated' do
    expect(File).to exist(dist)
  end

  it 'is valid ruby' do
    _, err, status = Open3.capture3('ruby', '-c', dist)
    expect(status).to be_success, err
  end

  it 'contains no requires of the module own files' do
    expect(File.read(dist)).not_to match(%r{require\s+['"]puppet_otel/})
  end

  it 'does not hoist the lazily loaded OpenTelemetry requires' do
    # They must stay inside the method that rescues LoadError, so that a
    # missing gem disables telemetry instead of failing the run.
    # Only the require lines are inspected; the generated banner legitimately
    # names the gems in its installation note.
    header = File.read(dist).split('# --- ').first
    hoisted = header.lines.grep(%r{^require})
    expect(hoisted).not_to include(a_string_matching(%r{opentelemetry}))
  end

  it 'registers the report processor when loaded in a clean process' do
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.join(root, 'lib').inspect})
      require 'puppet'
      require #{dist.inspect}
      puts Puppet::Reports.report(:opentelemetry).nil? ? 'missing' : 'registered'
    RUBY

    out, err, status = Open3.capture3({ 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') },
                                      'bundle', 'exec', 'ruby', '-e', script, chdir: root)
    expect(status).to be_success, err
    expect(out).to include('registered')
  end

  it 'processes a report in a clean process without the OpenTelemetry gems' do
    # Simulates the install where the gems are missing: the processor must log
    # and carry on rather than raise into the agent run.
    script = <<~RUBY
      require 'puppet'
      require #{dist.inspect}

      module Kernel
        alias_method :original_require, :require
        def require(name)
          raise LoadError, "no such file -- \#{name}" if name.to_s.start_with?('opentelemetry')

          original_require(name)
        end
      end

      report = Object.new
      def report.host = 'n1.example.com'
      def report.environment = 'production'
      def report.status = 'changed'
      def report.metrics = {}
      report.extend(Puppet::Reports.report(:opentelemetry))
      report.process
      puts 'survived'
    RUBY

    out, err, status = Open3.capture3({ 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') },
                                      'bundle', 'exec', 'ruby', '-e', script, chdir: root)
    expect(status).to be_success, err
    expect(out).to include('survived')
  end
end
