# frozen_string_literal: true

require_relative 'test_helper'

class StreamTest < Minitest::Test
  include Zeolite::TestSupport

  NDJSON = <<~JSON
    {"role":"user","content":"one"}
    {"role":"assistant","content":"two"}
    {"role":"user","content":"three"}
  JSON

  def test_reads_one_result_per_line
    results = Zeolite.stream(StringIO.new(NDJSON), MESSAGE).to_a

    assert_equal 3, results.size
    assert(results.all?(&:ok?))
    assert_equal(%w[one two three], results.map { |r| r.value.content })
  end

  def test_a_bad_record_does_not_stop_the_stream_and_reports_its_line
    text = %({"role":"user","content":"ok"}\n{"role":"nope","content":"bad"}\n{"role":"user","content":"ok2"}\n)
    results = Zeolite.stream(StringIO.new(text), MESSAGE).to_a

    assert_equal [true, false, true], results.map(&:ok?)
    assert_equal 2, results[1].violations.first.line
  end

  def test_blank_lines_and_a_missing_final_newline_are_tolerated
    text = %(\n{"role":"user","content":"a"}\n\n\n{"role":"user","content":"b"})
    results = Zeolite.stream(StringIO.new(text), MESSAGE).to_a

    assert_equal(%w[a b], results.map { |r| r.value.content })
  end

  def test_crlf_terminated_lines
    text = %({"role":"user","content":"a"}\r\n{"role":"user","content":"b"}\r\n)
    results = Zeolite.stream(StringIO.new(text), MESSAGE).to_a

    assert_equal(%w[a b], results.map { |r| r.value.content })
  end

  # The point of the whole exercise: a record split across arbitrary chunk
  # boundaries must still arrive whole, at every boundary.
  def test_records_survive_every_chunk_size
    (1..17).each do |size|
      io = Zeolite::TestSupport::ChunkedIO.new(NDJSON, size)
      results = Zeolite.stream(io, MESSAGE).to_a

      assert_equal %w[one two three], results.map { |r| r.value.content }, "chunk size #{size}"
    end
  end

  # Splitting on 0x0A cannot land inside a UTF-8 sequence, but only if the
  # buffer is held as bytes. A one-byte-at-a-time reader proves it.
  def test_multibyte_content_survives_byte_sized_chunks
    text = %({"role":"user","content":"日本語のテスト"}\n{"role":"user","content":"絵文字🍣"}\n)
    io = Zeolite::TestSupport::ChunkedIO.new(text, 1)
    results = Zeolite.stream(io, MESSAGE).to_a

    assert_equal(['日本語のテスト', '絵文字🍣'], results.map { |r| r.value.content })
    assert(results.all? { |r| r.value.content.encoding == Encoding::UTF_8 })
  end

  # Laziness is about how far the *source* is pulled, not about how many
  # results are materialised: a consumer that stops after one record must not
  # cause the rest of the stream to be read.
  def test_it_stops_pulling_chunks_once_the_consumer_stops
    pulled = []
    chunks = Enumerator.new do |yielder|
      NDJSON.each_line do |line|
        pulled << line
        yielder << line
      end
    end

    first = Zeolite.stream(chunks, MESSAGE).first

    assert_equal 'one', first.value.content
    assert_equal 1, pulled.size
  end

  def test_the_whole_stream_is_still_available_when_the_consumer_wants_it
    io = Zeolite::TestSupport::ChunkedIO.new(NDJSON, 8)

    assert_equal 3, Zeolite.stream(io, MESSAGE).count
  end

  def test_an_endless_line_is_capped_and_the_stream_resynchronises
    text = %({"role":"user","content":"#{'x' * 500}"}\n{"role":"user","content":"after"}\n)
    results = Zeolite.stream(StringIO.new(text), MESSAGE, max_line_bytes: 128).to_a

    assert_equal [false, true], results.map(&:ok?)
    assert_equal :line_too_long, results.first.violations.first.code
    assert_equal 'after', results.last.value.content
  end

  def test_sse_framing_reads_data_lines_and_ignores_the_done_sentinel
    text = <<~SSE
      : keep-alive

      event: message
      data: {"role":"user","content":"a"}

      data: {"role":"assistant","content":"b"}

      data: [DONE]

    SSE
    results = Zeolite.stream(StringIO.new(text), MESSAGE, framing: :sse).to_a

    assert_equal(%w[a b], results.map { |r| r.value.content })
  end

  def test_sse_multiline_data_is_joined_before_parsing
    text = "data: {\"role\":\"user\",\ndata: \"content\":\"split\"}\n\n"
    results = Zeolite.stream(StringIO.new(text), MESSAGE, framing: :sse).to_a

    assert_equal(['split'], results.map { |r| r.value.content })
  end

  def test_feed_is_the_push_side_of_the_same_framer
    feed = Zeolite.feed(MESSAGE)
    seen = []
    feed.push(%({"role":"user","cont)) { |r| seen << r }

    assert_empty seen

    feed.push(%(ent":"a"}\n{"role":"user","content":"b"})) { |r| seen << r }

    assert_equal(['a'], seen.map { |r| r.value.content })

    feed.finish { |r| seen << r }

    assert_equal(%w[a b], seen.map { |r| r.value.content })
  end

  def test_feed_returns_results_when_no_block_is_given
    feed = Zeolite.feed(MESSAGE)

    assert_empty feed.push(%({"role":"user",))
    assert_equal(['a'], feed.push(%("content":"a"}\n)).map { |r| r.value.content })
  end

  def test_a_string_and_an_enumerable_of_chunks_are_both_valid_sources
    from_string = Zeolite.stream(NDJSON, MESSAGE).to_a
    from_chunks = Zeolite.stream(NDJSON.chars.each_slice(9).map(&:join), MESSAGE).to_a

    assert_equal 3, from_string.size
    assert_equal(from_string.map { |r| r.value.content }, from_chunks.map { |r| r.value.content })
  end
end
