# frozen_string_literal: true

module Zeolite
  # Emits RBS for the classes a schema generates. Records become real classes
  # (they are Data subclasses at runtime, not Hashes), so nested objects get
  # their own declaration rather than an inline record type that would lie
  # about the value's shape.
  module Rbs
    module_function

    def emit(type, name)
      declarations = []
      root = ref(type, name, declarations)
      declarations << "# top-level value: #{root}" unless type.is_a?(Record)
      declarations.join("\n\n")
    end

    def ref(type, name, declarations)
      case type
      when Record then record_ref(type, name, declarations)
      when Nilable then "#{ref(type.inner, name, declarations)}?"
      when ArrayOf then "Array[#{ref(type.inner, singularize(name), declarations)}]"
      when MapOf then "Hash[String, #{ref(type.inner, singularize(name), declarations)}]"
      when Refined then ref(type.inner, name, declarations)
      when OneOf then union_ref(type, name, declarations)
      else type.rbs
      end
    end

    def union_ref(type, name, declarations)
      branches = type.alternatives.each_with_index.map do |alternative, index|
        ref(alternative, "#{name}#{index + 1}", declarations)
      end
      "(#{branches.join(' | ')})"
    end

    def record_ref(type, name, declarations)
      class_name = constantize(type.label || name)
      members = type.fields.map do |field, field_type|
        [field, ref(field_type, "#{class_name}#{camelize(field)}", declarations)]
      end
      declarations << class_declaration(class_name, members)
      class_name
    end

    def class_declaration(class_name, members)
      readers = members.map { |field, rbs| "  attr_reader #{field}: #{rbs}" }
      shape = members.map { |field, rbs| "#{field}: #{rbs}" }.join(', ')
      [
        "class #{class_name} < ::Data",
        *readers,
        "  def to_h: () -> { #{shape} }",
        'end'
      ].join("\n")
    end

    def constantize(name)
      camelize(name.to_s.gsub(/[^A-Za-z0-9_]/, '_'))
    end

    def camelize(name)
      name.to_s.split('_').map { |part| part.empty? ? part : part[0].upcase + part[1..] }.join
    end

    def singularize(name)
      name.to_s.sub(/(ie)s\z/, 'y').sub(/(?<!s)s\z/, '')
    end
  end
end
