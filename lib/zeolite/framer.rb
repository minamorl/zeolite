# frozen_string_literal: true

module Zeolite
  # Cuts a byte stream into JSON payloads. Chunk boundaries are arbitrary — they
  # land mid-line and mid-codepoint — so the buffer is held as binary and split
  # on 0x0A, which cannot occur inside a UTF-8 multibyte sequence. Only complete
  # lines are re-tagged as UTF-8.
  #
  # Emits [:payload, text, line] or [:error, code, message, line].
  class Framer
    DEFAULT_MAX_LINE_BYTES = 1 << 20

    FRAMINGS = %i[ndjson sse].freeze

    SSE_DONE = '[DONE]'

    attr_reader :framing, :max_line_bytes

    def initialize(framing: :ndjson, max_line_bytes: DEFAULT_MAX_LINE_BYTES)
      raise ArgumentError, "framing must be one of #{FRAMINGS.join(', ')}" unless FRAMINGS.include?(framing)

      @framing = framing
      @max_line_bytes = max_line_bytes
      @buffer = +''.b
      @line = 0
      @discarding = false
      @sse_data = []
      @sse_line = nil
    end

    def push(chunk, &)
      @buffer << chunk.to_s.b
      while (index = @buffer.index("\n"))
        raw = @buffer.slice!(0, index + 1)
        # This line is the tail of an oversized one already reported; drop it
        # rather than parse a fragment.
        if @discarding
          @discarding = false
          @line += 1
        else
          take(raw.chomp, &)
        end
      end
      overflow(&)
      self
    end

    # Flushes whatever is left: a final line with no trailing newline, or a
    # pending SSE event that never got its blank separator.
    def finish(&)
      unless @buffer.empty?
        raw = @buffer.slice!(0, @buffer.bytesize)
        @discarding ? @discarding = false : take(raw, &)
      end
      flush_sse(&) if @framing == :sse
      self
    end

    private

    # The budget is enforced here rather than only on the unterminated tail:
    # a fast producer can deliver an oversized line already newline-terminated,
    # and that must be refused too or the cap is bypassed whenever the network
    # happens to be quick.
    def take(raw, &emit)
      if raw.bytesize > @max_line_bytes
        @line += 1
        return emit.call([:error, :line_too_long, "line exceeds max_line_bytes #{@max_line_bytes}", @line])
      end

      handle_line(raw.chomp("\r").force_encoding(Encoding::UTF_8), &emit)
    end

    def handle_line(line, &)
      @line += 1
      @framing == :sse ? handle_sse(line, &) : handle_ndjson(line, &)
    end

    def handle_ndjson(line, &emit)
      stripped = line.strip
      return if stripped.empty?

      emit.call([:payload, stripped, @line])
    end

    # Server-Sent Events: `data:` payloads accumulate until a blank line ends
    # the event. Comments, ids and event names are not JSON and are skipped.
    def handle_sse(line, &)
      return flush_sse(&) if line.strip.empty?
      return if line.start_with?(':')

      field, _, value = line.partition(':')
      return unless field == 'data'

      @sse_line ||= @line
      @sse_data << value.delete_prefix(' ')
    end

    def flush_sse(&emit)
      return if @sse_data.empty?

      payload = @sse_data.join("\n").strip
      line = @sse_line
      @sse_data = []
      @sse_line = nil
      return if payload.empty? || payload == SSE_DONE

      emit.call([:payload, payload, line])
    end

    # A stream that never sends a newline must not be allowed to grow the
    # buffer without bound; report it and resynchronise at the next newline.
    def overflow(&emit)
      return if @discarding || @buffer.bytesize <= @max_line_bytes

      @buffer.clear
      @discarding = true
      emit.call([:error, :line_too_long, "line exceeds max_line_bytes #{@max_line_bytes}", @line + 1])
    end
  end
end
