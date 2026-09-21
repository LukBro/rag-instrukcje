# frozen_string_literal: true

namespace :docs do
  desc "Sprawdza dokumentację użytkownika: etykiety UI vs config/locales, front matter, verified_by"
  task lint: :environment do
    issues = DocsLint.call(root: Rails.root, locale: ENV.fetch("DOCS_LOCALE", "pl"))
    issues.each { |issue| puts issue }

    errors = issues.count { |i| i.level == "error" }
    warnings = issues.size - errors
    puts "docs:lint - błędy: #{errors}, ostrzeżenia: #{warnings}"
    abort if errors.positive?
  end
end
