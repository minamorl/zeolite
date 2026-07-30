# frozen_string_literal: true

require_relative 'test_helper'

# The "symbol-safe" claim, made checkable. Document keys and values are attacker
# input; symbols are process-global and only collected under specific
# conditions, so nothing here may turn input text into a Symbol unless the
# schema itself named it first.
class SafetyTest < Minitest::Test
  include Zeolite::TestSupport

  def interned?(text)
    Symbol.all_symbols.any? { |symbol| symbol.to_s == text }
  end

  def test_undeclared_keys_never_become_symbols
    key = %w[zeolite probe undeclared 9f3a71].join('_')

    refute interned?(key), 'precondition: the probe key must not already be interned'

    MESSAGE.parse(%({"role":"user","content":"hi","#{key}":1}))

    refute interned?(key)
  end

  def test_reporting_an_unknown_key_does_not_intern_it_either
    key = %w[zeolite probe reported c04e12].join('_')
    result = MESSAGE.strict.parse(%({"role":"user","content":"hi","#{key}":1}))

    assert_equal :unknown_key, result.violations.first.code
    assert_includes result.violations.first.path, key
    refute interned?(key)
  end

  def test_map_of_keeps_untrusted_keys_as_strings
    key = %w[zeolite probe mapped 5b1d90].join('_')
    schema = Zeolite.schema(extra: Zeolite.map_of(:integer))
    value = schema.parse(%({"extra":{"#{key}":1}})).value

    assert_equal({ key => 1 }, value.extra)
    assert_equal [String], value.extra.keys.map(&:class)
    refute interned?(key)
  end

  def test_enum_values_outside_the_declared_set_never_become_symbols
    candidate = %w[zeolite probe role ab77ce].join('_')
    result = MESSAGE.parse(%({"role":"#{candidate}","content":"hi"}))

    assert_equal :not_in_enum, result.violations.first.code
    refute interned?(candidate)
  end

  def test_enum_yields_the_symbol_the_schema_declared
    value = MESSAGE.parse('{"role":"assistant","content":"hi"}').value

    assert_same :assistant, value.role
  end

  def test_parsed_values_are_frozen_data_and_arrays
    schema = Zeolite.schema(tags: [:string], extra: Zeolite.map_of(:integer))
    value = schema.parse('{"tags":["a"],"extra":{"k":1}}').value

    assert_predicate value, :frozen?
    assert_predicate value.tags, :frozen?
    assert_predicate value.extra, :frozen?
  end

  def test_json_document_classes_are_not_revived
    # JSON.parse (not JSON.load) is used precisely so that a `json_class` key is
    # inert data rather than an instruction to instantiate something.
    schema = Zeolite.schema(payload: Zeolite.map_of(:any))
    value = schema.parse('{"payload":{"json_class":"Struct","v":[1]}}').value

    assert_equal({ 'json_class' => 'Struct', 'v' => [1] }, value.payload)
  end

  # Two guards on two different axes, because they protect different things.
  #
  # Document depth is bounded by the JSON parser: a schema of `map_of(:any)`
  # never walks the document, so only JSON.parse stands between a hostile blob
  # and the heap.
  def test_nesting_limit_refuses_a_deep_document_the_schema_would_not_walk
    depth = 2000
    document = "#{'{"a":' * depth}1#{'}' * depth}"

    result = Zeolite.schema(Zeolite.map_of(:any)).parse(document)

    refute_predicate result, :ok?
    assert_equal :invalid_json, result.violations.first.code
    assert_predicate Zeolite.schema(Zeolite.map_of(:any)).nesting_limit(4).parse('{"a":{"b":1}}'), :ok?
  end

  # Schema depth is bounded by max_depth: it caps our own recursion, which is
  # the only recursion `cast` performs.
  def test_depth_guard_caps_the_schemas_own_recursion
    nested = (1..40).inject(:integer) { |inner, _| Zeolite.map_of(inner) }
    document = (1..40).inject(1) { |inner, _| { 'a' => inner } }

    result = Zeolite.schema(nested).load(document)

    refute_predicate result, :ok?
    assert_equal :too_deep, result.violations.first.code
    assert_predicate Zeolite.schema(nested).depth_limit(64).load(document), :ok?
  end
end
