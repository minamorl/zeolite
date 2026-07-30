# frozen_string_literal: true

# Typed reading of Ollama's NDJSON chat stream, over a real socket.
#
#   ruby -Ilib examples/ollama_stream.rb [model]
#
# Net::HTTP hands you chunks rather than lines, which is exactly the case
# `Zeolite.feed` exists for: push bytes in as they land, get one typed Result
# out per complete record.

require 'net/http'
require 'zeolite'

MODEL = ARGV.fetch(0, 'qwen3.6:27b')

Chunk = Zeolite.schema(
  model: :string,
  created_at: :time,
  message: { role: Zeolite.enum(:assistant, :user, :system, :tool), content: :string },
  done: :boolean,
  done_reason: :string?,
  eval_count: :integer?
).named(:Chunk)

uri = URI('http://localhost:11434/api/chat')
request = Net::HTTP::Post.new(uri, 'content-type' => 'application/json')
request.body = JSON.generate(
  model: MODEL,
  stream: true,
  think: false,
  messages: [{ role: 'user', content: 'Name three minerals. One line, no preamble.' }]
)

feed = Zeolite.feed(Chunk)
text = +''
records = 0
rejected = []

Net::HTTP.start(uri.host, uri.port, read_timeout: 300) do |http|
  http.request(request) do |response|
    response.read_body do |bytes|
      feed.push(bytes) do |result|
        records += 1
        if result.ok?
          text << result.value.message.content
          print result.value.message.content
        else
          rejected << result
        end
      end
    end
  end
end
feed.finish { |result| rejected << result unless result.ok? }

puts
puts '---'
puts "records: #{records}, rejected: #{rejected.size}"
rejected.each { |result| puts result.violations.map(&:to_s) }
puts "text bytes: #{text.bytesize}"
