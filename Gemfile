# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.2.2'

# Rails API
gem 'rails', '~> 7.1.3'
gem 'pg', '~> 1.5'
gem 'puma', '~> 6.4'

# Auth
gem 'jwt', '~> 2.7'

# HTTP client for Cloudflare API
gem 'faraday', '~> 2.9'
gem 'faraday-retry', '~> 2.2'

# CLI
gem 'thor', '~> 1.3'

# Env loading
gem 'dotenv-rails', '~> 3.0'

# Boot
gem 'bootsnap', '>= 1.4.4', require: false

# Timezone data for Windows (harmless on Linux)
gem 'tzinfo-data', platforms: %i[mingw mswin x64_mingw jruby]

group :development, :test do
  gem 'debug', platforms: %i[mri mingw x64_mingw]
  gem 'rspec-rails', '~> 6.1'
  gem 'rubocop-rails-omakase', require: false
end

group :development do
  gem 'listen', '~> 3.8'
end
