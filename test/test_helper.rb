# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'zeolite'

module Zeolite
  module TestSupport
    MESSAGE = Zeolite.schema(
      role: Zeolite.enum(:user, :assistant),
      content: :string,
      tokens: :integer?
    ).named(:Message)

    # An IO that hands out `size` bytes at a time, so tests can drive records
    # across chunk boundaries the way a socket does.
    class ChunkedIO
      def initialize(text, size)
        @bytes = text.b
        @size = size
        @offset = 0
      end

      def readpartial(_max)
        raise EOFError if @offset >= @bytes.bytesize

        chunk = @bytes.byteslice(@offset, @size)
        @offset += chunk.bytesize
        chunk
      end
    end
  end
end
