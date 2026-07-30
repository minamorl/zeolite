# frozen_string_literal: true

module Zeolite
  # Compiles the symbol/array/hash literal that you write by hand into the Type
  # tree that does the work. The schema is plain Ruby data — there is no DSL to
  # learn and nothing to `instance_eval`.
  module Build
    module_function

    def call(spec, unknown_keys: :ignore, label: nil)
      case spec
      when Type then spec
      when Symbol then from_symbol(spec)
      when Array then from_array(spec, unknown_keys, label)
      when Hash then record(spec, unknown_keys: unknown_keys, label: label)
      when String, Integer, Float, true, false, nil then Literal.new(spec)
      else raise SchemaError, "cannot build a type from #{spec.inspect}"
      end
    end

    # Nested objects inherit a derived label (`Message` -> `MessageMeta`) so the
    # class a value prints as matches the class the emitted RBS declares.
    def record(spec, unknown_keys: :ignore, label: nil)
      fields = spec.to_h do |name, field|
        raise SchemaError, "field name must be a Symbol, got #{name.inspect}" unless name.is_a?(Symbol)

        [name, call(field, unknown_keys: unknown_keys, label: nested_label(label, name))]
      end
      Record.new(fields, unknown_keys: unknown_keys, label: label)
    end

    def nested_label(label, name)
      return nil unless label

      "#{Rbs.camelize(label)}#{Rbs.camelize(name)}"
    end

    # `:string` -> Prim, `:string?` -> Nilable[Prim]. The trailing `?` is the
    # whole optionality vocabulary at the leaf level.
    def from_symbol(spec)
      name = spec.to_s
      return Nilable.new(from_symbol(name.delete_suffix('?').to_sym)) if name.end_with?('?')

      Prim.new(spec)
    end

    def from_array(spec, unknown_keys, label = nil)
      raise SchemaError, 'array spec needs exactly one element type, e.g. [:string]' unless spec.size == 1

      element_label = label && Rbs.singularize(label)
      ArrayOf.new(call(spec.first, unknown_keys: unknown_keys, label: element_label))
    end
  end
end
