# frozen_string_literal: true

# A minimal stand-in for Puppet::Resource::Status, which the trace mapping
# reads one span per entry from.
class FakeResourceStatus
  attr_reader :resource, :resource_type, :title, :evaluation_time, :file, :line, :time,
              :changed, :out_of_sync, :failed, :skipped

  def initialize(resource: 'File[/tmp/example]', resource_type: 'File', title: '/tmp/example',
                 evaluation_time: 0.5, changed: true, out_of_sync: true, failed: false,
                 skipped: false, file: '/etc/puppetlabs/code/site.pp', line: 12, time: nil)
    @resource = resource
    @resource_type = resource_type
    @title = title
    @evaluation_time = evaluation_time
    @changed = changed
    @out_of_sync = out_of_sync
    @failed = failed
    @skipped = skipped
    @file = file
    @line = line
    @time = time
  end
end
