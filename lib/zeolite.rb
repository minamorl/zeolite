# frozen_string_literal: true

require_relative 'zeolite/version'
require_relative 'zeolite/result'
require_relative 'zeolite/type'
require_relative 'zeolite/rbs'
require_relative 'zeolite/build'
require_relative 'zeolite/schema'
require_relative 'zeolite/framer'
require_relative 'zeolite/stream'

# Zeolite is a molecular sieve for JSON: a schema written as ordinary Ruby data
# admits exactly the documents that fit its shape, and hands back typed values
# instead of a Hash of unknown provenance.
#
#   Message = Zeolite.schema(
#     role:    Zeolite.enum(:user, :assistant),
#     content: :string,
#     tokens:  :integer?
#   ).named(:Message)
#
#   Message.parse('{"role":"user","content":"hi"}').value.role  # => :user
#   Zeolite.stream(socket, Message).each { |result| ... }       # NDJSON, lazily
module Zeolite
  module_function

  # Build a schema. Pass fields as keywords for the common case, or a single
  # spec positionally when the top level is not an object (`Zeolite.schema([:string])`).
  def schema(spec = nil, **fields)
    raise SchemaError, 'pass either a positional spec or keyword fields, not both' if spec && !fields.empty?

    Schema.new(spec.nil? ? fields : spec)
  end

  # A closed set of strings. This is the only construct that turns document text
  # into a Symbol, and it can only produce symbols the schema already names —
  # so untrusted keys and values can never grow the symbol table.
  def enum(*values)
    Enum.new(values.flatten)
  end

  def one_of(*specs)
    OneOf.new(specs.flatten.map { |spec| Build.call(spec) })
  end

  def optional(spec)
    Nilable.new(Build.call(spec))
  end

  # An object whose keys you do not control. Values are typed, keys stay
  # Strings.
  def map_of(spec)
    MapOf.new(Build.call(spec))
  end

  def array_of(spec)
    ArrayOf.new(Build.call(spec))
  end

  def literal(value)
    Literal.new(value)
  end

  # Attach a predicate to an already-typed value: ranges, lengths, formats.
  # (Named `check` rather than `refine` so it does not shadow Module#refine.)
  def check(spec, label, &predicate)
    Refined.new(Build.call(spec), label, predicate)
  end

  def range(spec, min: nil, max: nil)
    label = "between #{min || '-inf'} and #{max || 'inf'}"
    check(spec, label) { |value| (min.nil? || value >= min) && (max.nil? || value <= max) }
  end

  def sized(spec, min: nil, max: nil)
    label = "length between #{min || 0} and #{max || 'inf'}"
    check(spec, label) { |value| (min.nil? || value.size >= min) && (max.nil? || value.size <= max) }
  end

  def matching(pattern)
    check(:string, "matches #{pattern.inspect}") { |value| pattern.match?(value) }
  end

  # Lazily yield one Result per newline-delimited record read from `source`,
  # which may be an IO, a socket, a String, or any object that `each`es chunks.
  def stream(source, schema, framing: :ndjson, max_line_bytes: Framer::DEFAULT_MAX_LINE_BYTES)
    Stream.call(source, schema, framing: framing, max_line_bytes: max_line_bytes)
  end

  # Push-mode counterpart to `stream`, for transports that hand you chunks.
  def feed(schema, framing: :ndjson, max_line_bytes: Framer::DEFAULT_MAX_LINE_BYTES)
    Feed.new(schema, framing: framing, max_line_bytes: max_line_bytes)
  end
end
