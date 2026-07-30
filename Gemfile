# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
gem 'rubocop', '~> 1.64', require: false
gem 'rubocop-minitest', '~> 0.35', require: false

# Development only: the RBS emitter's test feeds its own output back to the
# real parser, so that "typed" means a type checker actually accepts it.
gem 'rbs', '~> 3.0', require: false
