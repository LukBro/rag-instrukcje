require "rails_helper"

RSpec.describe Rag::QuestionRewriter do
  def ok_response(text) = Rag::GeminiClient::Response.new(text: text, finish_reason: "STOP", usage: {})

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  let(:history) { ["jak dodać adres dostawy klienta?"] }

  it "przepisuje pytanie na samodzielne, przekazując historię do modelu" do
    gem = FakeGemini.new(response: ok_response("Jak usunąć adres dostawy klienta?\n"))

    with_env("RAG_GEMINI_API_KEY" => "k") do
      result = described_class.call("a jak to usunąć?", history: history, env: "development", client: gem)

      expect(result).to eq("Jak usunąć adres dostawy klienta?")
    end

    expect(gem.calls.size).to eq(1)
    expect(gem.calls.first[:user_text]).to include("jak dodać adres dostawy klienta?")
    expect(gem.calls.first[:user_text]).to include("a jak to usunąć?")
    expect(gem.calls.first[:max_output_tokens]).to eq(described_class::MAX_OUTPUT_TOKENS)
  end

  it "nie woła API bez historii ani przy wyłączonym Gemini" do
    gem = FakeGemini.new(response: ok_response("cokolwiek"))

    with_env("RAG_GEMINI_API_KEY" => "k") do
      expect(described_class.call("a jak to usunąć?", history: [], env: "development", client: gem)).to be_nil
    end
    with_env("RAG_GEMINI_API_KEY" => nil) do
      expect(described_class.call("a jak to usunąć?", history: history, env: "development", client: gem)).to be_nil
    end

    expect(gem.calls).to be_empty
  end

  it "zwraca nil przy błędzie API i przy pustej odpowiedzi" do
    with_env("RAG_GEMINI_API_KEY" => "k") do
      failing = FakeGemini.new(error: Rag::GeminiClient::Error.new("500"))
      expect(described_class.call("a jak to?", history: history, env: "development", client: failing)).to be_nil

      limited = FakeGemini.new(error: Rag::GeminiClient::RateLimited.new("429"))
      expect(described_class.call("a jak to?", history: history, env: "development", client: limited)).to be_nil

      empty = FakeGemini.new(response: ok_response("   "))
      expect(described_class.call("a jak to?", history: history, env: "development", client: empty)).to be_nil
    end
  end

  it "zwraca nil, gdy model oddał samo pytanie bez zmian lub pustą treść po obcięciu" do
    with_env("RAG_GEMINI_API_KEY" => "k") do
      gem = FakeGemini.new(response: ok_response("a jak to usunąć?"))

      expect(described_class.call("a jak to usunąć?", history: history, env: "development", client: gem)).to be_nil
    end
  end

  it "ogranicza historię do ostatnich pytań i obcina zbyt długie" do
    gem = FakeGemini.new(response: ok_response("Jak usunąć adres dostawy klienta?"))
    long = "a" * 900
    many = (1..8).map { |i| "pytanie #{i}" } + [long]

    with_env("RAG_GEMINI_API_KEY" => "k") do
      described_class.call("a jak to usunąć?", history: many, env: "development", client: gem)
    end

    sent = gem.calls.first[:user_text]
    expect(sent).not_to include("pytanie 1")
    expect(sent).to include("pytanie 8")
    expect(sent).to include("a" * described_class::MAX_QUESTION_CHARS)
    expect(sent).not_to include("a" * (described_class::MAX_QUESTION_CHARS + 1))
  end

  it "ignoruje historię, która nie jest tablicą stringów" do
    gem = FakeGemini.new(response: ok_response("cokolwiek"))

    with_env("RAG_GEMINI_API_KEY" => "k") do
      expect(described_class.call("a jak to?", history: "nie tablica", env: "development", client: gem)).to be_nil
      expect(described_class.call("a jak to?", history: [nil, ""], env: "development", client: gem)).to be_nil
    end

    expect(gem.calls).to be_empty
  end
end
