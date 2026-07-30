# frozen_string_literal: true

module Zeolite
  # A single rejection, located by JSON Pointer. `line` is filled in by the
  # streaming reader; a one-shot `parse` leaves it nil.
  Violation = Data.define(:path, :code, :message, :line) do
    def self.[](path, code, message, line: nil)
      new(path: path, code: code, message: message, line: line)
    end

    def at_line(number)
      with(line: number)
    end

    def pointer
      path.empty? ? '/' : path
    end

    def to_s
      prefix = line ? "line #{line} " : ''
      "#{prefix}#{pointer}: #{message} [#{code}]"
    end
  end

  class ValidationError < StandardError
    attr_reader :violations

    def initialize(violations)
      @violations = violations.freeze
      super(violations.join('; '))
    end
  end

  # Ok / Err are the whole return protocol: nothing raises unless you ask it to
  # with `unwrap`. The shape (`ok?` / `value` / `|`) matches Berylx::Result so a
  # schema can sit inside a Berylx task without an adapter.
  Ok = Data.define(:value) do
    def ok? = true
    def err? = false
    def violations = [].freeze
    def unwrap = value
    def value_or(_fallback) = value
    def map = Ok.new(value: yield(value))
    def |(other) = other.call(value)
  end

  Err = Data.define(:violations) do
    def ok? = false
    def err? = true
    def value = nil
    def unwrap = raise(ValidationError, violations)
    def value_or(fallback) = fallback
    def map = self
    def |(_other) = self

    def at_line(number)
      with(violations: violations.map { |v| v.at_line(number) })
    end

    def message
      violations.join('; ')
    end
  end
end
