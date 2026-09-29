require "rails_helper"

RSpec.describe Rag::Catalog do
  include_context "rag fakes"

  it "zwraca jedną pozycję na plik, posortowaną po tytule" do
    fake_redis.search_result = [
      3,
      "rag:chunk:b:0", ["source", "docs/user/b.md", "title", "Zażółć".b],
      "rag:chunk:a:0", ["source", "docs/user/a.md", "title", "Anulowanie"],
      "rag:chunk:b:1", ["source", "docs/user/b.md", "title", "Zażółć".b]
    ]

    entries = described_class.call

    expect(entries.map(&:source)).to eq(%w[docs/user/a.md docs/user/b.md])
    expect(entries.last.title).to eq("Zażółć")
    expect(entries.last.title.encoding).to eq(Encoding::UTF_8)
    expect(fake_redis.calls.last.first(3)).to eq(["FT.SEARCH", Rag::Index::NAME, "*"])
  end
end
