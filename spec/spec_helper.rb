# frozen_string_literal: true

ENV['COVERAGE'] ||= 'yes' if Dir.exist?(File.expand_path('../lib', __dir__))

require 'voxpupuli/test/spec_helper'

RSpec.configure do |c|
  c.facterdb_string_keys = false
end

add_mocked_facts!

Dir['./spec/support/spec/**/*.rb'].sort.each { |f| require f }
