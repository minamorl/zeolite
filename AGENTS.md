# AGENTS.md

## Project

Zeolite parses JSON against schemas written as plain Ruby data and returns generated `Data`
instances. Three properties define it; a change that weakens any of them is a redesign, not a patch:

1. **Schemas are data.** Symbols, arrays, and hashes — no DSL, no `instance_eval`, nothing to learn
   beyond the table in the README.
2. **Untrusted text never becomes a Symbol.** `Zeolite.enum` is the single exception and it can only
   emit symbols the schema already declared. `symbolize_names` must not appear in this repository.
3. **Streaming is record-at-a-time.** `stream` is a lazy Enumerator and `feed` is its push
   counterpart; neither may buffer more than the longest single record.

## Repository rules

- Read `README.md` before changing the design.
- No runtime dependencies. `json` and `time` are default gems; nothing else may be added.
- `JSON.parse`, never `JSON.load` — a `json_class` key must stay inert data.
- Every guard has a test that would fail if the guard were deleted: symbol interning, `max_depth`,
  `max_nesting`, `max_line_bytes`. Do not add a limit without one.
- The framer holds its buffer as binary and splits on `0x0A`. Do not "simplify" it to `each_line` or
  to string-mode buffering; that reintroduces the multi-byte chunk-boundary bug that
  `test_multibyte_content_survives_byte_sized_chunks` exists to catch.
- `Ok`/`Err` keep the berylx `Result` shape (`ok?`, `value`, `|`). Changing it breaks composition
  with berylx workflows.
- Emitted RBS must parse. `test/rbs_test.rb` feeds it to the real `RBS::Parser`; keep it that way
  rather than asserting on strings alone.
- Keep the gem buildable with `gem build zeolite.gemspec`.

## Commands

```sh
bundle install
bundle exec rake          # tests + rubocop
bundle exec rake test
bundle exec rubocop
ruby -Ilib examples/ollama_stream.rb   # live NDJSON against a local Ollama
```

## Before handing off

Run tests, rubocop, and `gem build`.
