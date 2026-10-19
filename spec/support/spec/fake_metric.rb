# frozen_string_literal: true

# Mirrors Puppet::Util::Metric: #values returns [id, label, value] triples.
class FakeMetric
  attr_reader :values

  def initialize(values)
    @values = values
  end
end
