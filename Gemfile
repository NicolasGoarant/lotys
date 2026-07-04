source "https://rubygems.org"
ruby "3.3.0"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 7.2.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Épinglage minitest — sans plafond, Bundler résout sur la dernière publiée
  # (actuellement 6.x), qui a retiré Minitest.run_one_method au niveau du module.
  # ActiveSupport 7.2 fait encore cet appel dans sa parallélisation des tests,
  # ce qui fait planter silencieusement les workers et fige `bin/rails test`.
  gem "minitest", "~> 5.25"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

gem "devise"
gem "devise-i18n"

# API Claude
gem "httparty"           # pour DVF API

# Upload & traitement documents
gem "image_processing", "~> 1.2"
# Extraction texte PDF : shell-out à `pdftotext -layout` (poppler-utils,
# cf. Aptfile). L'ancienne gem pdf-reader ne préservait pas la mise en
# page tabulaire des DPE, ce qui coupait libellé/valeur.

# UI
gem "pagy"               # pagination
gem "noticed"            # notifications (offres reçues côté propriétaire)

group :development, :test do
  gem "dotenv-rails"
  gem "faker"
end

gem "redcarpet"

gem "good_job"

gem "aws-sdk-s3", "~> 1.219"

gem "mini_magick", "~> 5.3"
gem "rack-attack"
gem "rails-i18n", "~> 7.0"
