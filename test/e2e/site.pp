# Manifest for the end to end test.
#
# Deliberately small but not empty: the run must produce resources, changes
# and events, otherwise the report would contain nothing worth exporting and
# the assertions could pass against an empty catalogue.

node default {
  file { '/tmp/otel_e2e':
    ensure  => directory,
    mode    => '0755',
  }

  file { '/tmp/otel_e2e/marker.txt':
    ensure  => file,
    content => "written by the end to end test\n",
    require => File['/tmp/otel_e2e'],
  }

  notify { 'otel-e2e-notify':
    message => 'end to end test applied',
  }
}
