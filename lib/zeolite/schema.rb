# frozen_string_literal: true

require 'json'

module Zeolite
  # The public handle on a compiled schema. Immutable: every option method
  # returns a new Schema, so a schema constant can be shared without a lock.
  class Schema
    DEFAULT_MAX_DEPTH = 32
    DEFAULT_MAX_NESTING = 64

    attr_reader :spec, :unknown_keys, :max_depth, :max_nesting, :label, :type

    def initialize(spec, unknown_keys: :ignore, max_depth: DEFAULT_MAX_DEPTH,
                   max_nesting: DEFAULT_MAX_NESTING, label: nil)
      @spec = spec
      @unknown_keys = unknown_keys
      @max_depth = max_depth
      @max_nesting = max_nesting
      @label = label
      @type = Build.call(spec, unknown_keys: unknown_keys, label: label)
      freeze
    end

    # The generated Data subclass, for record schemas. This is the "typed" in
    # typed parse: `schema.data_class` is a real class with real readers, and
    # instances pattern-match like any other Data.
    def data_class
      @type.is_a?(Record) ? @type.data_class : nil
    end

    def named(label)
      with(label: label)
    end

    def strict
      with(unknown_keys: :error)
    end

    def lenient
      with(unknown_keys: :ignore)
    end

    # How deep the schema itself is allowed to walk. Since `cast` only recurses
    # where the schema recurses, this bounds our own stack; it does not bound
    # document depth under `:any` or `map_of` — `nesting_limit` does that.
    def depth_limit(limit)
      with(max_depth: limit)
    end

    # How deep a *document* may nest before JSON.parse refuses it, independent
    # of what the schema looks at.
    def nesting_limit(limit)
      with(max_nesting: limit)
    end

    # JSON text in, Ok(typed value) or Err(violations) out. Nothing raises.
    #
    # Note what is *not* passed to JSON.parse: `symbolize_names`. Document keys
    # arrive as Strings and are matched against the declared key set; only names
    # written in the schema ever reach `Symbol#to_sym`.
    def parse(text)
      load(JSON.parse(text, max_nesting: @max_nesting))
    rescue JSON::ParserError => e
      Err.new(violations: [Violation['', :invalid_json, e.message.lines.first.to_s.strip]])
    end

    # Same, for an object you already parsed (or built by hand).
    def load(document)
      value, violations = @type.cast(document, '', Ctx.new(depth: 0, max_depth: @max_depth))
      violations.empty? ? Ok.new(value: value) : Err.new(violations: violations.freeze)
    end

    def parse!(text) = parse(text).unwrap
    def load!(document) = load(document).unwrap
    def valid?(document) = load(document).ok?

    # An RBS declaration for the generated classes, so `steep` can check the
    # code that consumes a parse result.
    def to_rbs(name: @label || 'Parsed')
      Rbs.emit(@type, name)
    end

    def inspect
      "#<Zeolite::Schema #{@label || '(anonymous)'} #{@type.describe} unknown_keys=#{@unknown_keys}>"
    end

    private

    def with(**changes)
      Schema.new(
        @spec,
        unknown_keys: changes.fetch(:unknown_keys, @unknown_keys),
        max_depth: changes.fetch(:max_depth, @max_depth),
        max_nesting: changes.fetch(:max_nesting, @max_nesting),
        label: changes.fetch(:label, @label)
      )
    end
  end
end
