require "rails_helper"

RSpec.describe Rag::Search do
  include_context "rag fakes"

  it "wybiera najlepszą sekcję na plik, stosuje próg i limit" do
    fake_redis.search_result = [5,
      *resp_row("a0", source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "kroki A", distance: 0.10),
      *resp_row("a1", source: "docs/user/a.md", title: "A", heading: "A › Wynik", content: "wynik A", distance: 0.15),
      *resp_row("b0", source: "docs/user/b.md", title: "B", heading: "B", content: "B", distance: 0.20),
      *resp_row("c0", source: "docs/user/c.md", title: "C", heading: "C", content: "C", distance: 0.30),
      *resp_row("d0", source: "docs/user/d.md", title: "D", heading: "D", content: "D", distance: 0.40)]
    r = described_class.call("pytanie")
    expect(r.found?).to be true
    expect(r.results.map { |x| x[:source] }).to eq(%w[docs/user/a.md docs/user/b.md docs/user/c.md])
    expect(r.results[0][:content]).to eq("kroki A")
    expect(r.suggestions).to be_empty
    search = fake_redis.calls.find { |c| c.first == "FT.SEARCH" }
    expect(search[search.index("LIMIT"), 3]).to eq(["LIMIT", "0", Rag::Search::CANDIDATES.to_s])
  end

  it "przy braku wyników zwraca tytuły podpowiedzi" do
    fake_redis.search_result = [3,
      *resp_row("a0", source: "docs/user/a.md", title: "A", heading: "A", content: "A", distance: 0.70),
      *resp_row("a1", source: "docs/user/a.md", title: "A", heading: "A › S", content: "A2", distance: 0.72),
      *resp_row("b0", source: "docs/user/b.md", title: "B", heading: "B", content: "B", distance: 0.80)]
    r = described_class.call("coś spoza zakresu")
    expect(r.found?).to be false
    expect(r.suggestions).to eq([{ source: "docs/user/a.md", title: "A", distance: 0.70 },
                                  { source: "docs/user/b.md", title: "B", distance: 0.80 }])
    expect(r.suggestions.first).not_to have_key(:content)
  end

  it "dla pustego pytania nie woła Ollama" do
    r = described_class.call("   ")
    expect(r.found?).to be false
    expect(fake_ollama.embed_calls).to be_empty
  end
end
