# Zeolite

**A molecular sieve for JSON. Schemas are Ruby data, results are typed, streams are newline-delimited.**

A zeolite is a mineral whose pore structure admits only molecules that fit its shape. This gem is
the same idea for JSON: you declare a shape with ordinary Ruby symbols, and what comes back is a
generated `Data` class — not a Hash of unknown provenance.

```ruby
require 'zeolite'

Message = Zeolite.schema(
  role:    Zeolite.enum(:user, :assistant),
  content: :string,
  tokens:  :integer?
).named(:Message)

Message.parse('{"role":"user","content":"hi"}')
# => #<data Zeolite::Ok value=#<Message role=:user content="hi" tokens=nil>>

Message.parse('{"role":"root","content":42}').violations.map(&:to_s)
# => ["/role: expected one of user, assistant, got \"root\" [not_in_enum]",
#     "/content: expected string, got integer [type_mismatch]"]
```

## Why this exists

Ruby already has a good JSON Schema **validator** ([`json_schemer`][json_schemer]) and good
**streaming** parsers ([`yajl-ruby`][yajl], [`json-stream`][json-stream], `Oj`), and good **typed**
mappers ([`shale`][shale], [`dry-struct`][dry-struct]). What it does not have is one thing that is
all three at once — a schema that reads a newline-delimited stream and hands back typed values,
record by record, without ever loading the whole stream.

That is the shape of every LLM API in existence (Ollama emits NDJSON; OpenAI-compatible and
Anthropic endpoints emit SSE), so that is what this gem is for.

## Install

```ruby
gem 'zeolite'
```

Ruby 3.2 or newer, tested through Ruby 4.0. **No runtime dependencies** — `json` and `time` are
default gems. A validation boundary that drags in a dependency tree is a larger attack surface than
the thing it guards.

## Schemas are data

There is no DSL and nothing is `instance_eval`ed. A schema is the literal you would have written on
a napkin:

| you write | you get |
| --- | --- |
| `:string` `:integer` `:float` `:number` `:boolean` `:null` `:time` `:any` | the primitive |
| `:string?` | nilable *and* optional — absent and `null` both land on `nil` |
| `[:string]` | `Array` of that type |
| `{ city: :string }` | a nested object, which becomes a nested `Data` class |
| `Zeolite.enum(:user, :assistant)` | a closed set of strings, returned as symbols |
| `Zeolite.one_of(:integer, :string)` | first alternative that fits wins |
| `Zeolite.map_of(:integer)` | an object whose keys you do not control — keys stay `String` |
| `Zeolite.literal('chunk')` | an exact value |
| `Zeolite.range(:float, min: 0.0, max: 1.0)` | a bounded number |
| `Zeolite.sized(:string, max: 64)` | a bounded length |
| `Zeolite.matching(/\A[a-f0-9]+\z/)` | a pattern |
| `Zeolite.check(:integer, 'even', &:even?)` | any predicate you like |

Options are chainable and each one returns a **new** schema, so a schema constant is safe to share:

```ruby
Message.strict          # undeclared keys become violations instead of being dropped
Message.lenient         # (the default) drop them
Message.depth_limit(8)  # how deep the schema may walk
Message.nesting_limit(32) # how deep a document may nest before JSON.parse refuses it
```

Chain the options *before* you freeze the schema into a constant: each schema compiles its own
`Data` class, so `Message.data_class` and `Message.strict.data_class` are different classes.

## Results, not exceptions

`parse` and `load` return `Ok` or `Err`. Nothing raises unless you ask:

```ruby
result = Message.parse(text)
result.ok?          # => true / false
result.value        # the typed value, or nil
result.violations   # [] or the full list — every violation, not just the first
result.unwrap       # raises Zeolite::ValidationError
result.value_or(fallback)
```

Each `Violation` carries `path` (a JSON Pointer), `code` (a symbol: `:type_mismatch`,
`:missing_key`, `:unknown_key`, `:not_in_enum`, `:invalid_json`, `:too_deep`, `:line_too_long`,
`:refinement_failed`, `:not_literal`, `:invalid_format`), `message`, and `line` when it came from a
stream.

`Ok`/`Err` deliberately mirror [`berylx`][berylx]'s `Result` — `ok?`, `value`, `|` — so a schema
drops into a berylx task without an adapter.

## Streams

`Zeolite.stream` returns a lazy `Enumerator` of one `Result` per record. Memory is O(longest
record), not O(stream), and a bad record does not stop the good ones behind it:

```ruby
Zeolite.stream(socket, Message).each do |result|
  result.ok? ? handle(result.value) : log(result.violations)
end

Zeolite.stream(io, Message, framing: :sse)  # `data:` lines, `[DONE]` ignored
```

The source can be an `IO`, a socket, a `String`, or anything that `each`es chunks. `readpartial` is
used rather than `gets` on purpose: it returns as soon as bytes are available, so a slow producer's
first record is not held hostage by the second.

When the transport calls *you* — `Net::HTTP#read_body`, a websocket callback — use the push side:

```ruby
feed = Zeolite.feed(Message)
response.read_body { |bytes| feed.push(bytes) { |result| ... } }
feed.finish { |result| ... }
```

Chunk boundaries land wherever the network puts them, including inside a multi-byte character. The
buffer is held as bytes and split on `0x0A`, which cannot occur inside a UTF-8 sequence, so only
complete lines are ever re-tagged as UTF-8. `examples/ollama_stream.rb` runs the whole thing
against a live Ollama endpoint.

## Typed means a type checker agrees

`schema.data_class` is a real `Data` subclass: frozen instances, real readers, pattern matching.

```ruby
case Message.parse(line)
in Zeolite::Ok(value: {role: :assistant, content:}) then reply(content)
in Zeolite::Err(violations:)                        then log(violations)
end
```

And the signature can be emitted for `steep`/`rbs`:

```ruby
puts Message.to_rbs
# class Message < ::Data
#   attr_reader role: :user | :assistant
#   attr_reader content: String
#   attr_reader tokens: Integer?
#   def to_h: () -> { role: :user | :assistant, content: String, tokens: Integer? }
# end
```

The test suite feeds that output back to the real `RBS::Parser`, so "typed" is checked, not claimed.

## Symbol-safe

Symbols are process-global and only collected under specific conditions, so a parser that symbolizes
untrusted keys hands an attacker a knob on your heap. Zeolite never calls `symbolize_names`. Keys
arrive as `String` and are matched against the declared key set; the only construct that turns
document text into a `Symbol` is `Zeolite.enum`, and it can only produce symbols the schema itself
already named.

`test/safety_test.rb` asserts this the direct way — it parses documents containing probe keys and
then checks `Symbol.all_symbols` to prove they were never interned. The same file pins the other
boundaries: `JSON.parse` (not `JSON.load`), so a `json_class` key is inert data; `max_nesting` on
the document; `max_depth` on the schema's own recursion; and `max_line_bytes` on a stream that never
sends a newline.

## What it is not

- **Not a JSON Schema implementation.** It does not read `draft-2020-12` documents. If you need to
  consume a schema someone else published, use [`json_schemer`][json_schemer].
- **Not a partial-JSON parser.** It yields whole records. If you want to render a half-finished
  object as its tokens arrive, that is a different tool.
- **Not a coercer.** `"1"` is not an `Integer`. JSON already has types; guessing at the boundary is
  how bad data gets in.
- **Framing is NDJSON or SSE.** Whitespace-separated concatenated JSON values are not supported.

## Development

```sh
bundle install
bundle exec rake        # tests + rubocop
```

## License

MIT.

[json_schemer]: https://github.com/davishmcclurg/json_schemer
[yajl]: https://github.com/brianmario/yajl-ruby
[json-stream]: https://github.com/dgraham/json-stream
[shale]: https://github.com/kgiszczak/shale
[dry-struct]: https://github.com/dry-rb/dry-struct
[berylx]: https://github.com/minamorl/berylx
