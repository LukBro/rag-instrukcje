require "rails_helper"

RSpec.describe Rag::Answer do
  SOURCES = [
    { source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "1. Kliknij **Koryguj**.", distance: 0.1 },
    { source: "docs/user/b.md", title: "B", heading: "B", content: "Treść B", distance: 0.2 }
  ].freeze

  def found = Rag::Search::Result.new(results: SOURCES.map(&:dup), suggestions: [])
  def empty = Rag::Search::Result.new(results: [], suggestions: [{ source: "x", title: "X", distance: 0.9 }])
  def ok_response(text) = Rag::GeminiClient::Response.new(text: text, finish_reason: "STOP", usage: {})

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "enabled? wymaga klucza i środowiska development" do
    with_env("RAG_GEMINI_API_KEY" => nil, "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => nil) do
      expect(described_class.enabled?(env: "development")).to be false
    end
    with_env("RAG_GEMINI_API_KEY" => "k", "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => nil) do
      expect(described_class.enabled?(env: "development")).to be true
      expect(described_class.enabled?(env: "production")).to be false
    end
    with_env("RAG_GEMINI_API_KEY" => "k", "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => "1") do
      expect(described_class.enabled?(env: "production")).to be true
    end
  end

  it "wyłączone i brak wyników nie wołają API" do
    gem = FakeGemini.new(response: ok_response("x"))
    with_env("RAG_GEMINI_API_KEY" => nil) do
      r = described_class.call("p", env: "development", search_result: found, client: gem)
      expect(r.status).to eq(:disabled)
    end
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = described_class.call("p", env: "development", search_result: empty, client: gem)
      expect(r.status).to eq(:no_results)
    end
    expect(gem.calls).to be_empty
  end

  it "przy statusie ok prompt zawiera ponumerowane źródła" do
    gem = FakeGemini.new(response: ok_response("Kliknij Koryguj [1]."))
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = described_class.call("Jak poprawić fakturę?", env: "development", search_result: found, client: gem)
      expect(r.status).to eq(:ok)
      expect(r.sources.size).to eq(2)
    end
    call = gem.calls.first
    expect(call[:model]).to eq(Rag::Answer::MODEL)
    expect(call[:user_text]).to include("[1] A › Kroki (docs/user/a.md)\n1. Kliknij **Koryguj**.")
    expect(call[:user_text]).to include("[2] B (docs/user/b.md)")
    expect(call[:user_text]).to end_with("Pytanie: Jak poprawić fakturę?")
    expect(call[:system_instruction]).to include(Rag::Answer::NO_ANSWER)
  end

  it "obsługuje brak odpowiedzi w dokumentacji, pustą odpowiedź i błędy" do
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = described_class.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(response: ok_response(Rag::Answer::NO_ANSWER)))
      expect(r.status).to eq(:not_in_docs)

      r = described_class.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(response: Rag::GeminiClient::Response.new(text: "", finish_reason: "SAFETY", usage: {})))
      expect(r.status).to eq(:error)

      r = described_class.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(error: Rag::GeminiClient::RateLimited.new("429")))
      expect(r.status).to eq(:rate_limited)
      expect(r.sources.size).to eq(2)

      r = described_class.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(error: Rag::GeminiClient::Error.new("400")))
      expect(r.status).to eq(:error)
    end
  end

  it "citation_issues wykrywa brak i odwołania poza zakresem" do
    expect(described_class.citation_issues("Tak [1]. Potem [2].", 2)).to be_empty
    expect(described_class.citation_issues("Tak.", 2)).to eq(["brak odwołań [n]"])
    expect(described_class.citation_issues("Tak [3].", 2)).to eq(["odwołania poza zakresem: 3"])
    expect(described_class.citation_issues(Rag::Answer::NO_ANSWER, 2)).to be_empty
  end
end
