#!/usr/bin/env bash
#
# End to end test: agent -> server -> collector.
#
# Verifies the generated single file processor under the server's JRuby, which
# the unit tests cannot cover because they run on MRI.
#
# Usage: ./run.sh [--keep]
#   --keep  leave the stack running afterwards for inspection

set -euo pipefail

cd "$(dirname "$0")"

KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

COMPOSE="podman-compose -f compose.yaml"
SERVER=otel-e2e-server
AGENT=otel-e2e-agent
COLLECTOR=otel-e2e-collector

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '\033[36m==> %s\033[0m\n' "$*"; }

cleanup() {
  if [[ "$KEEP" == true ]]; then
    info "leaving stack running (--keep); tear down with: $COMPOSE down -v"
    return
  fi
  info 'tearing down'
  $COMPOSE down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Each failure path explains which layer broke, because "no metrics" on its own
# could equally mean the processor never loaded, the config was not found, or
# the collector never received anything.
fail() {
  red "FAIL: $*"
  echo
  info 'server report processor errors (last 30):'
  podman logs "$SERVER" 2>&1 | grep -i 'opentelemetry\|otel\|report' | tail -30 || true
  echo
  info 'collector log (last 20):'
  podman logs "$COLLECTOR" 2>&1 | tail -20 || true
  exit 1
}

info 'building dist/opentelemetry.rb'
(cd ../.. && bundle exec rake dist:build)

# The file exporter writes spans here and the assertions read them back from
# the host. It must exist before the collector starts: the exporter does not
# create missing parents and aborts startup if it cannot open the file, which
# takes the whole stack down with it. World writable because the collector
# runs as a non root user that does not match the host uid.
info 'preparing the span output directory'
mkdir -p spans
chmod 777 spans
# Removed rather than left in place, so spans from an earlier run cannot
# satisfy the assertions and hide a broken export.
rm -f spans/spans.json

info 'starting stack'
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d

info 'waiting for the server to accept connections (up to 5 minutes)'
deadline=$((SECONDS + 300))
until podman exec "$SERVER" curl -ksf https://localhost:8140/status/v1/simple >/dev/null 2>&1; do
  ((SECONDS >= deadline)) && fail 'server did not become ready within 5 minutes'
  sleep 5
done
green 'server is up'

# The OpenTelemetry gems are not in the image, and the processor degrades
# gracefully when they are missing, so a run without them would silently prove
# nothing. They are installed into the server's JRuby here, which is also what
# the README instructs operators to do.
info 'installing the OpenTelemetry gems into the server JRuby'
if podman exec "$SERVER" test -d /opt/puppetlabs/server/data/puppetserver/jruby-gems/gems; then
  if podman exec "$SERVER" sh -c 'ls /opt/puppetlabs/server/data/puppetserver/jruby-gems/gems | grep -q "^opentelemetry-sdk-"'; then
    green 'gems already installed, skipping'
    gems_installed=false
  else
    podman exec "$SERVER" puppetserver gem install --no-document \
      opentelemetry-sdk opentelemetry-metrics-sdk opentelemetry-exporter-otlp-metrics opentelemetry-exporter-otlp \
      || fail 'could not install the OpenTelemetry gems into the server JRuby'
    gems_installed=true
  fi
else
  podman exec "$SERVER" puppetserver gem install --no-document \
    opentelemetry-sdk opentelemetry-metrics-sdk opentelemetry-exporter-otlp-metrics opentelemetry-exporter-otlp \
    || fail 'could not install the OpenTelemetry gems into the server JRuby'
  gems_installed=true
fi

# JRuby caches its load path at startup, so freshly installed gems are only
# visible after a restart.
if [[ "$gems_installed" == true ]]; then
  info 'restarting the server so JRuby picks up the new gems'
  podman restart "$SERVER" >/dev/null
  deadline=$((SECONDS + 300))
  until podman exec "$SERVER" curl -ksf https://localhost:8140/status/v1/simple >/dev/null 2>&1; do
    ((SECONDS >= deadline)) && fail 'server did not come back after the gem install restart'
    sleep 5
  done
  green 'server is back up'
fi

# Confirms the environment variable actually reached puppet.conf. If this is
# wrong the processor never runs and every later assertion is meaningless.
info 'verifying the processor is enabled'
reports=$(podman exec "$SERVER" puppet config print reports --section server 2>/dev/null || echo '')
echo "    reports = ${reports:-<unset>}"
[[ "$reports" == *opentelemetry* ]] || fail "reports setting does not include opentelemetry (got: ${reports:-<unset>})"

# Confirms the processor found its configuration. A missing otel.yaml is not an
# error in the code, it silently falls back to localhost, so it is asserted here.
info 'verifying otel.yaml is readable by the server'
podman exec "$SERVER" test -r /etc/puppetlabs/puppet/otel.yaml \
  || fail 'otel.yaml is not readable at /etc/puppetlabs/puppet/otel.yaml'

info 'running the agent'
set +e
# Called by absolute path: the entrypoint override in compose.yaml means an
# exec session does not inherit the image PATH, which includes
# /opt/puppetlabs/bin.
agent_out=$(podman exec "$AGENT" /opt/puppetlabs/bin/puppet agent --test \
  --server puppet --masterport 8140 --waitforcert 0 --detailed-exitcodes 2>&1)
agent_rc=$?
set -e
echo "$agent_out" | tail -20
# 0 = no changes, 2 = changes applied. 4/6 indicate failed resources.
if [[ $agent_rc -ne 0 && $agent_rc -ne 2 ]]; then
  fail "agent run failed (exit $agent_rc)"
fi
green "agent run completed (exit $agent_rc)"

info 'waiting for metrics to reach the collector'
deadline=$((SECONDS + 60))
metrics=''
until [[ -n "$metrics" ]]; do
  ((SECONDS >= deadline)) && fail 'no puppet metrics appeared on the collector within 60 seconds'
  metrics=$(curl -sf http://localhost:8889/metrics 2>/dev/null | grep '^puppet_' || true)
  [[ -z "$metrics" ]] && sleep 5
done

echo
green 'metrics received:'
echo "$metrics" | head -40
echo

info 'asserting on the exported series'
failed=0
for metric in puppet_report_resources puppet_report_time puppet_report_changes \
              puppet_report_events puppet_run_status puppet_report_duration; do
  if echo "$metrics" | grep -q "^${metric}"; then
    green "  ok   $metric"
  else
    red "  MISS $metric"
    failed=1
  fi
done

# The node name proves data point attributes survive the OTLP round trip.
if echo "$metrics" | grep -q 'puppet_node_name='; then
  green '  ok   puppet_node_name attribute present'
else
  red '  MISS puppet_node_name attribute'
  failed=1
fi

[[ $failed -eq 0 ]] || fail 'one or more expected metrics were missing'

# Traces are enabled in otel.yaml, so spans must have reached the collector.
# Asserted separately from metrics: the two signals use different providers and
# exporters, so one working proves nothing about the other.
info 'waiting for spans to reach the collector'
deadline=$((SECONDS + 60))
spans=''
until [[ -n "$spans" ]]; do
  ((SECONDS >= deadline)) && fail 'no spans appeared on the collector within 60 seconds'
  # Read from the host bind mount, not from inside the container: the
  # collector image is distroless, so "podman exec ... cat" can never work.
  spans=$(cat spans/spans.json 2>/dev/null || true)
  [[ -z "$spans" ]] && sleep 5
done

info 'asserting on the exported spans'
span_failed=0

# The root span proves the run itself was traced.
if echo "$spans" | grep -q '"puppet.run"'; then
  green '  ok   puppet.run root span present'
else
  red '  MISS puppet.run root span'
  span_failed=1
fi

# A resource span proves the per resource child spans were emitted.
if echo "$spans" | grep -q 'puppet.resource.type'; then
  green '  ok   resource spans present'
else
  red '  MISS resource spans'
  span_failed=1
fi

# Proves the resource attributes reached the span, as they do for metrics.
if echo "$spans" | grep -q 'puppet.node.name'; then
  green '  ok   puppet.node.name attribute present on spans'
else
  red '  MISS puppet.node.name attribute on spans'
  span_failed=1
fi

[[ $span_failed -eq 0 ]] || fail 'one or more expected spans were missing'

echo
green 'END TO END TEST PASSED'
