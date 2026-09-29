require "rails_helper"

RSpec.describe Rag::Conversation do
  let(:catalog) do
    [Rag::Catalog::Entry.new(source: "docs/user/a.md", title: "Temat A"),
     Rag::Catalog::Entry.new(source: "docs/user/b.md", title: "Temat B")]
  end
  let(:nearest) { [{ source: "docs/user/b.md", title: "Temat B", distance: 0.48 }] }

  def ok_response(text) = Rag::GeminiClient::Response.new(text: text, finish_reason: "STOP", usage: {})

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def converse(gem, message: "w czym możesz pomóc?", history: [], catalog: self.catalog)
    with_env("RAG_GEMINI_API_KEY" => "k") do
      described_class.call(message, history: history, env: "development", catalog: catalog,
                                    nearest: nearest, client: gem)
    end
  end

  it "zwraca tekst i tematy z katalogu, z dystansem tylko dla najbliższych" do
    gem = FakeGemini.new(response: ok_response('{"reply": " Pomagam w A i B. ", "topics": [2, 1]}'))

    result = converse(gem)

    expect(result.text).to eq("Pomagam w A i B.")
    expect(result.suggestions).to eq(
      [{ source: "docs/user/b.md", title: "Temat B", distance: 0.48 },
       { source: "docs/user/a.md", title: "Temat A", distance: nil }]
    )
  end

  it "wysyła katalog, historię i wiadomość oraz wymusza JSON" do
    gem = FakeGemini.new(response: ok_response('{"reply": "Cześć!", "topics": []}'))

    converse(gem, message: "a co u ciebie?", history: ["siemanko"])

    sent = gem.calls.first
    expect(sent[:user_text]).to include("1. Temat A\n2. Temat B")
    expect(sent[:user_text]).to include("- siemanko")
    expect(sent[:user_text]).to end_with("Wiadomość: a co u ciebie?")
    expect(sent[:response_schema]).to eq(described_class::RESPONSE_SCHEMA)
    expect(sent[:max_output_tokens]).to eq(described_class::MAX_OUTPUT_TOKENS)
    expect(sent[:system_instruction]).to include("Nigdy nie opisuj, jak coś zrobić")
  end

  it "odrzuca numery spoza listy, nie-liczby i powtórzenia; najwyżej 3 tematy" do
    five = (1..5).map { |i| Rag::Catalog::Entry.new(source: "docs/user/#{i}.md", title: "T#{i}") }
    gem = FakeGemini.new(response: ok_response('{"reply": "Ok", "topics": [0, 6, -1, "2", 3, 3, 1, 4, 5]}'))

    result = converse(gem, catalog: five)

    expect(result.suggestions.map { |s| s[:source] }).to eq(%w[docs/user/3.md docs/user/1.md docs/user/4.md])
    empty_catalog = converse(FakeGemini.new(response: ok_response('{"reply": "Ok", "topics": [1]}')), catalog: [])
    expect(empty_catalog.text).to eq("Ok")
    expect(empty_catalog.suggestions).to eq([])
  end

  it "zwraca nil przy złym JSON, pustym reply, błędzie i limicie" do
    ["Cześć!", "[1, 2]", '{"reply": "   ", "topics": [1]}', '{"topics": [1]}'].each do |text|
      expect(converse(FakeGemini.new(response: ok_response(text)))).to be_nil
    end
    expect(converse(FakeGemini.new(error: Rag::GeminiClient::Error.new("500")))).to be_nil
    expect(converse(FakeGemini.new(error: Rag::GeminiClient::RateLimited.new("429")))).to be_nil
  end

  it "nie woła API przy wyłączonym Gemini ani pustej wiadomości" do
    gem = FakeGemini.new(response: ok_response('{"reply": "x", "topics": []}'))

    with_env("RAG_GEMINI_API_KEY" => nil) do
      expect(described_class.call("siemanko", history: [], env: "development", catalog: catalog, client: gem)).to be_nil
    end
    expect(converse(gem, message: "  ")).to be_nil
    expect(gem.calls).to be_empty
  end
end
