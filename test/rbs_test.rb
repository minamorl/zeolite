# frozen_string_literal: true

require_relative 'test_helper'

begin
  require 'rbs'
rescue LoadError
  RBS = nil
end

# The "typed" claim is only worth anything if a type checker accepts the
# output, so the emitted signature is fed back to the real RBS parser.
class RbsTest < Minitest::Test
  include Zeolite::TestSupport

  SCHEMA = Zeolite.schema(
    role: Zeolite.enum(:user, :assistant),
    content: :string,
    tokens: :integer?,
    tags: [:string],
    meta: { model: :string, temperature: :float },
    extra: Zeolite.map_of(:any),
    id: Zeolite.one_of(:integer, :string)
  ).named(:Message)

  def test_emits_a_class_per_record
    source = SCHEMA.to_rbs

    assert_includes source, 'class Message < ::Data'
    assert_includes source, 'class MessageMeta < ::Data'
    assert_includes source, 'attr_reader role: :user | :assistant'
    assert_includes source, 'attr_reader tokens: Integer?'
    assert_includes source, 'attr_reader tags: Array[String]'
    assert_includes source, 'attr_reader meta: MessageMeta'
    assert_includes source, 'attr_reader extra: Hash[String, untyped]'
    assert_includes source, 'attr_reader id: (Integer | String)'
  end

  def test_the_emitted_signature_parses_as_rbs
    skip 'rbs is not installed' unless defined?(RBS) && RBS

    buffer = RBS::Buffer.new(name: Pathname('zeolite_generated.rbs'), content: SCHEMA.to_rbs)
    _, _, declarations = RBS::Parser.parse_signature(buffer)

    assert_equal %w[Message MessageMeta], declarations.map { |d| d.name.to_s }.sort
  end

  # The generated class names and the runtime class names must agree, or the
  # signature describes something the program never produces.
  def test_runtime_class_names_match_the_declared_ones
    value = SCHEMA.parse(<<~JSON).unwrap
      {"role":"user","content":"hi","tags":[],
       "meta":{"model":"m","temperature":0.2},"extra":{},"id":1}
    JSON

    assert_equal 'Message', value.class.name
    assert_equal 'MessageMeta', value.meta.class.name
    assert_includes value.inspect, '#<Message '
  end
end
