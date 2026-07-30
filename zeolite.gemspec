# frozen_string_literal: true

require_relative 'lib/zeolite/version'

Gem::Specification.new do |spec|
  spec.name = 'zeolite'
  spec.version = Zeolite::VERSION
  spec.summary = 'Typed JSON schemas as Ruby data, over newline-delimited streams'
  spec.description = 'A molecular sieve for JSON: schemas written as plain Ruby data parse into ' \
                     'generated Data classes, report violations by JSON Pointer, stream NDJSON and ' \
                     'SSE lazily, and never turn untrusted document text into Symbols.'
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/zeolite'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir[
    'lib/**/*.rb',
    'README.md',
    'LICENSE',
    'AGENTS.md'
  ]
  spec.require_paths = ['lib']

  # No runtime dependencies. `json` and `time` are default gems; everything
  # else is this gem's own code, because a validation boundary that drags in a
  # dependency tree is a larger attack surface than the thing it guards.
end
