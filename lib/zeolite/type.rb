# frozen_string_literal: true

require 'time'

module Zeolite
  class SchemaError < StandardError; end

  # Runtime budget carried down the tree. Depth is the only thing that grows,
  # so a hostile document cannot blow the stack before `max_depth` stops it.
  Ctx = Data.define(:depth, :max_depth) do
    def deeper = with(depth: depth + 1)
    def exhausted? = depth > max_depth
  end

  Options = Data.define(:unknown_keys, :max_depth, :name)

  # Every type answers one question: `cast(value, path, ctx) -> [value, violations]`.
  # `violations` empty means the first element is the accepted, converted value.
  class Type
    NONE = [].freeze

    # JSON.parse produces exactly these classes, so a lookup is both the whole
    # answer and cheaper than a case chain.
    KINDS = {
      NilClass => 'null', TrueClass => 'boolean', FalseClass => 'boolean',
      String => 'string', Integer => 'integer', Float => 'float',
      Array => 'array', Hash => 'object'
    }.freeze

    def self.kind_of(value)
      KINDS[value.class] || value.class.name.to_s.downcase
    end

    def cast(_value, _path, _ctx)
      raise NotImplementedError
    end

    # True when a missing key is acceptable (nilable types only).
    def optional? = false

    def rbs = 'untyped'

    def describe = 'value'

    private

    def reject(path, code, message)
      [nil, [Violation[path, code, message]]]
    end

    def mismatch(value, path)
      reject(path, :type_mismatch, "expected #{describe}, got #{Type.kind_of(value)}")
    end
  end

  class Prim < Type
    PREDICATES = {
      string: ->(v) { v.is_a?(String) },
      integer: ->(v) { v.is_a?(Integer) },
      float: ->(v) { v.is_a?(Float) || v.is_a?(Integer) },
      number: ->(v) { v.is_a?(Integer) || v.is_a?(Float) },
      boolean: ->(v) { [true, false].include?(v) },
      null: ->(v) { v.is_a?(NilClass) },
      time: ->(v) { v.is_a?(String) },
      any: ->(_v) { true }
    }.freeze

    RBS = {
      string: 'String', integer: 'Integer', float: 'Float', number: 'Numeric',
      boolean: 'bool', null: 'nil', time: 'Time', any: 'untyped'
    }.freeze

    attr_reader :name

    def initialize(name)
      raise SchemaError, "unknown primitive #{name.inspect}" unless PREDICATES.key?(name)

      @name = name
      super()
    end

    def cast(value, path, _ctx)
      return mismatch(value, path) unless PREDICATES[@name].call(value)

      case @name
      when :float then [value.to_f, NONE]
      when :time then parse_time(value, path)
      else [value, NONE]
      end
    end

    def rbs = RBS.fetch(@name)
    def describe = @name.to_s

    private

    def parse_time(value, path)
      [Time.iso8601(value), NONE]
    rescue ArgumentError
      reject(path, :invalid_format, 'expected an ISO 8601 timestamp')
    end
  end

  # `:string?` — absent or null both land on nil. Presence and nullness are
  # deliberately collapsed: over a token stream the distinction is noise.
  class Nilable < Type
    attr_reader :inner

    def initialize(inner)
      @inner = inner
      super()
    end

    def cast(value, path, ctx)
      return [nil, NONE] if value.nil?

      @inner.cast(value, path, ctx)
    end

    def optional? = true
    def rbs = "#{@inner.rbs}?"
    def describe = "#{@inner.describe} or null"
  end

  class ArrayOf < Type
    attr_reader :inner

    def initialize(inner)
      @inner = inner
      super()
    end

    def cast(value, path, ctx)
      return mismatch(value, path) unless value.is_a?(Array)

      inner_ctx = ctx.deeper
      return reject(path, :too_deep, "nesting exceeds max_depth #{ctx.max_depth}") if inner_ctx.exhausted?

      out = []
      errs = []
      value.each_with_index do |element, index|
        cast, violations = @inner.cast(element, "#{path}/#{index}", inner_ctx)
        violations.empty? ? out << cast : errs.concat(violations)
      end
      errs.empty? ? [out.freeze, NONE] : [nil, errs]
    end

    def rbs = "Array[#{@inner.rbs}]"
    def describe = 'array'
  end

  # Free-form object with typed values. Keys stay Strings — this is the escape
  # hatch for input whose key set you do not control, so it must never mint
  # symbols.
  class MapOf < Type
    attr_reader :inner

    def initialize(inner)
      @inner = inner
      super()
    end

    def cast(value, path, ctx)
      return mismatch(value, path) unless value.is_a?(Hash)

      inner_ctx = ctx.deeper
      return reject(path, :too_deep, "nesting exceeds max_depth #{ctx.max_depth}") if inner_ctx.exhausted?

      out = {}
      errs = []
      value.each do |key, element|
        cast, violations = @inner.cast(element, "#{path}/#{key}", inner_ctx)
        violations.empty? ? out[key.to_s] = cast : errs.concat(violations)
      end
      errs.empty? ? [out.freeze, NONE] : [nil, errs]
    end

    def rbs = "Hash[String, #{@inner.rbs}]"
    def describe = 'object'
  end

  # A closed set of strings, and the only place in Zeolite where input becomes a
  # Symbol. The candidate must already be a member, so the symbol table can only
  # grow by as much as the schema itself declares.
  class Enum < Type
    attr_reader :values

    def initialize(values)
      raise SchemaError, 'enum needs at least one value' if values.empty?

      @values = values.map(&:to_sym).freeze
      @lookup = @values.to_h { |v| [v.to_s, v] }.freeze
      super()
    end

    def cast(value, path, _ctx)
      return mismatch(value, path) unless value.is_a?(String) || value.is_a?(Symbol)

      member = @lookup[value.to_s]
      return [member, NONE] if member

      reject(path, :not_in_enum,
             "expected one of #{@values.join(', ')}, got #{value.to_s.inspect}")
    end

    def rbs = @values.map { |v| ":#{v}" }.join(' | ')
    def describe = 'string'
  end

  class Literal < Type
    attr_reader :value

    def initialize(value)
      @value = value.freeze
      super()
    end

    def cast(value, path, _ctx)
      return [@value, NONE] if value == @value

      reject(path, :not_literal, "expected #{@value.inspect}, got #{value.inspect}")
    end

    def rbs
      case @value
      when String, Integer, Float, true, false then @value.inspect
      when nil then 'nil'
      else 'untyped'
      end
    end

    def describe = @value.inspect
  end

  # First alternative that accepts wins. On total failure the report names every
  # branch rather than the last one tried.
  class OneOf < Type
    attr_reader :alternatives

    def initialize(alternatives)
      raise SchemaError, 'one_of needs at least one alternative' if alternatives.empty?

      @alternatives = alternatives.freeze
      super()
    end

    def cast(value, path, ctx)
      @alternatives.each do |alternative|
        cast, violations = alternative.cast(value, path, ctx)
        return [cast, NONE] if violations.empty?
      end
      mismatch(value, path)
    end

    def optional? = @alternatives.any?(&:optional?)
    def rbs = "(#{@alternatives.map(&:rbs).join(' | ')})"
    def describe = @alternatives.map(&:describe).join(' or ')
  end

  # A predicate on an already-typed value: ranges, lengths, formats.
  class Refined < Type
    attr_reader :inner, :label

    def initialize(inner, label, predicate)
      @inner = inner
      @label = label
      @predicate = predicate
      super()
    end

    def cast(value, path, ctx)
      cast, violations = @inner.cast(value, path, ctx)
      return [nil, violations] unless violations.empty?
      return [cast, NONE] if @predicate.call(cast)

      reject(path, :refinement_failed, "#{@label} not satisfied by #{cast.inspect}")
    end

    def optional? = @inner.optional?
    def rbs = @inner.rbs
    def describe = "#{@inner.describe} (#{@label})"
  end

  # An object with a known key set, which compiles to a real Data subclass.
  # Field names come from the schema, never from the document, so `cast` reads
  # input by String key and only ever writes developer-declared symbols.
  class Record < Type
    attr_reader :fields, :unknown_keys, :label, :data_class

    def initialize(fields, unknown_keys: :ignore, label: nil)
      unless %i[ignore error].include?(unknown_keys)
        raise SchemaError, "unknown_keys must be :ignore or :error, got #{unknown_keys.inspect}"
      end

      @fields = fields.freeze
      @unknown_keys = unknown_keys
      @label = label
      @keys = fields.keys.to_h { |name| [name.to_s, name] }.freeze
      @data_class = build_data_class
      super()
    end

    def cast(value, path, ctx)
      return mismatch(value, path) unless value.is_a?(Hash)

      inner_ctx = ctx.deeper
      return reject(path, :too_deep, "nesting exceeds max_depth #{ctx.max_depth}") if inner_ctx.exhausted?

      attrs = {}
      errs = []
      @fields.each do |name, type|
        field, violations = read_field(name, type, value, path, inner_ctx)
        violations.empty? ? attrs[name] = field : errs.concat(violations)
      end
      errs.concat(unknown_violations(value, path)) if @unknown_keys == :error
      errs.empty? ? [@data_class.new(**attrs), NONE] : [nil, errs]
    end

    def rbs = @label ? @label.to_s : "{ #{@fields.map { |n, t| "#{n}: #{t.rbs}" }.join(', ')} }"
    def describe = 'object'

    private

    # Reads by String key, so a declared field name is the only thing that ever
    # becomes a Symbol here.
    def read_field(name, type, value, path, ctx)
      key = name.to_s
      field_path = "#{path}/#{key}"
      return type.cast(value[key], field_path, ctx) if value.key?(key)
      return [nil, NONE] if type.optional?

      [nil, [Violation[field_path, :missing_key, "required key #{key.inspect} is absent"]]]
    end

    def unknown_violations(value, path)
      (value.keys.map(&:to_s) - @keys.keys).map do |key|
        Violation["#{path}/#{key}", :unknown_key, "key #{key.inspect} is not declared"]
      end
    end

    # A named schema gets its name back at the C level nowhere — Data#inspect
    # reads the class path, which stays anonymous — so the label is applied by
    # overriding inspect on both the class and its instances. Without this a
    # parsed value prints as `#<data ...>` and says nothing about which schema
    # admitted it.
    def build_data_class
      klass = Data.define(*@fields.keys)
      return klass unless @label

      label = @label.to_s
      klass.define_singleton_method(:name) { label }
      klass.define_singleton_method(:inspect) { label }
      klass.define_method(:inspect) do
        "#<#{label} #{to_h.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')}>"
      end
      klass.alias_method(:to_s, :inspect)
      klass
    rescue ArgumentError, NameError => e
      raise SchemaError, "invalid field name in #{@fields.keys.inspect}: #{e.message}"
    end
  end
end
