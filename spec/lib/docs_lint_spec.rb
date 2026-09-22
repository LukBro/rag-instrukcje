require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe DocsLint do
  it "zgłasza brakujące pola, nieistniejące pliki, złe daty, złe questions i etykiety spoza locales" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config/locales"))
      FileUtils.mkdir_p(File.join(dir, "docs/user"))
      FileUtils.mkdir_p(File.join(dir, "test/system/docs"))
      File.write(File.join(dir, "config/locales/pl.yml"), <<~YML)
        pl:
          invoices:
            new: "Nowa faktura"
            created: "Utworzono fakturę nr %{number}"
      YML
      File.write(File.join(dir, "test/system/docs/ok_test.rb"), "")
      File.write(File.join(dir, "docs/user/ok.md"), <<~MD)
        ---
        title: OK
        audience: Księgowy
        verified_by: [test/system/docs/ok_test.rb]
        last_verified: 2026-09-01
        questions:
          - Jak dodać fakturę?
        ---
        # OK
        1. Kliknij **Nowa faktura**.
        Wynik: **Utworzono fakturę nr 12**.
        ```
        **Nie sprawdzaj w kodzie**
        ```
      MD
      File.write(File.join(dir, "docs/user/zle.md"), <<~MD)
        ---
        title: Złe
        verified_by: test/system/docs/brak_test.rb
        last_verified: wczoraj
        questions: "nie lista"
        ---
        # Złe
        Kliknij **Zapisz** jak wyżej.
      MD
      issues = described_class.call(root: dir)
      ok = issues.select { |i| i.location.start_with?("docs/user/ok.md") }
      expect(ok).to be_empty, ok.map(&:to_s).join("\n")
      msgs = issues.map(&:to_s).join("\n")
      expect(msgs).to match(/brak pola front matter: audience/)
      expect(msgs).to match(%r{nieistniejący plik: test/system/docs/brak_test.rb})
      expect(msgs).to match(/last_verified musi być datą/)
      expect(msgs).to match(/questions musi być listą/)
      expect(msgs).to match(/zle.md:8: etykieta \*\*Zapisz\*\*/)
      expect(msgs).to match(%r{WARNING docs/user/zle.md:8: odwołanie "jak wyżej"})
    end
  end
end
