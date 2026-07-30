# frozen_string_literal: true

module Zeolite
  # Push side of streaming: hand it bytes as they arrive, it hands back one
  # Result per complete record. Use this when the transport calls you (a
  # Net::HTTP `read_body` block, a websocket callback) instead of the other way
  # round.
  class Feed
    attr_reader :schema, :framer

    def initialize(schema, framing: :ndjson, max_line_bytes: Framer::DEFAULT_MAX_LINE_BYTES)
      @schema = schema
      @framer = Framer.new(framing: framing, max_line_bytes: max_line_bytes)
    end

    def push(chunk, &block)
      collect(block) { |emit| @framer.push(chunk, &emit) }
    end

    def finish(&block)
      collect(block) { |emit| @framer.finish(&emit) }
    end

    private

    def collect(block)
      results = block ? nil : []
      emit = lambda do |event|
        result = interpret(event)
        block ? block.call(result) : results << result
      end
      yield(emit)
      results
    end

    def interpret(event)
      case event
      in [:payload, text, line]
        result = @schema.parse(text)
        result.ok? ? result : result.at_line(line)
      in [:error, code, message, line]
        Err.new(violations: [Violation['', code, message, line: line]])
      end
    end
  end

  CHUNK_BYTES = 64 * 1024

  module Stream
    module_function

    # Lazily yields one Result per record. The Enumerator does not read ahead:
    # `stream(socket, schema).first` consumes exactly the first record's worth
    # of bytes, and memory stays O(longest record).
    def call(source, schema, framing: :ndjson, max_line_bytes: Framer::DEFAULT_MAX_LINE_BYTES)
      Enumerator.new do |yielder|
        feed = Feed.new(schema, framing: framing, max_line_bytes: max_line_bytes)
        each_chunk(source) { |chunk| feed.push(chunk) { |result| yielder << result } }
        feed.finish { |result| yielder << result }
      end
    end

    # `readpartial` is preferred over `gets` on purpose: it returns as soon as
    # any bytes are available, so a slow producer's first record is not held
    # hostage by the second.
    def each_chunk(source, &block)
      case source
      when String then block.call(source)
      else
        if source.respond_to?(:readpartial) then read_partial(source, &block)
        elsif source.respond_to?(:each) then source.each(&block)
        elsif source.respond_to?(:read) then block.call(source.read.to_s)
        else raise ArgumentError, "cannot stream from #{source.class}"
        end
      end
    end

    def read_partial(io)
      loop { yield io.readpartial(CHUNK_BYTES) }
    rescue EOFError
      nil
    end
  end
end
