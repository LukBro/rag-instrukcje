require "rails_helper"

RSpec.describe Rag::Ask do
  let(:sources) do
    [{ source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "Treść", distance: 0.12 }]
  end
  let(:found) { Rag::Search::Result.new(results: sources, suggestions: []) }
  let(:empty) do
    Rag::Search::Result.new(results: [], suggestions: [{ source: "docs/user/b.md", title: "B", distance: 0.8 }])
  end

  before do
    allow(Rag::Answer).to receive(:call).and_return(
      Rag::Answer::Result.new(status: :ok, sources: sources, text: "Odpowiedź")
    )
  end

  it "bez historii nie woła przepisywania i szuka raz" do
    allow(Rag::Search).to receive(:call).with("jak dodać klienta?").and_return(found)
    allow(Rag::QuestionRewriter).to receive(:call)

    result = described_class.call("jak dodać klienta?", history: [], env: "development")

    expect(result.answer.status).to eq(:ok)
    expect(result.rewritten_question).to be_nil
    expect(Rag::QuestionRewriter).not_to have_received(:call)
    expect(Rag::Search).to have_received(:call).once
  end

  # Sedno BRO-72: "a jak to usunąć?" trafia w losową instrukcję poniżej progu (zmierzone 0,3803),
  # więc przepisanie nie może zależeć od braku wyników.
  it "przepisuje pytanie, mimo że wyszukiwanie oryginału coś by znalazło" do
    allow(Rag::QuestionRewriter).to receive(:call).and_return("Jak usunąć adres dostawy klienta?")
    allow(Rag::Search).to receive(:call).with("Jak usunąć adres dostawy klienta?").and_return(found)

    result = described_class.call("a jak to usunąć?", history: ["jak dodać adres dostawy?"], env: "development")

    expect(result.rewritten_question).to eq("Jak usunąć adres dostawy klienta?")
    expect(Rag::Search).not_to have_received(:call).with("a jak to usunąć?")
    expect(Rag::Answer).to have_received(:call).with(
      "Jak usunąć adres dostawy klienta?", hash_including(search_result: found)
    )
  end

  it "używa pytania oryginalnego, gdy przepisanie zwróciło nil (pytanie samodzielne lub błąd)" do
    allow(Rag::QuestionRewriter).to receive(:call).and_return(nil)
    allow(Rag::Search).to receive(:call).with("jak usunąć klienta?").and_return(found)

    result = described_class.call("jak usunąć klienta?", history: ["poprzednie pytanie"], env: "development")

    expect(result.answer.status).to eq(:ok)
    expect(result.rewritten_question).to be_nil
    expect(Rag::Answer).to have_received(:call).with("jak usunąć klienta?", hash_including(search_result: found))
  end

  it "zwraca no_results z najbliższymi tematami, gdy rozmówca nie odpowiedział" do
    allow(Rag::QuestionRewriter).to receive(:call).and_return(nil)
    allow(Rag::Search).to receive(:call).and_return(empty)
    allow(Rag::Conversation).to receive(:call).and_return(nil)

    result = described_class.call("zupełnie nie z tej dokumentacji", history: [], env: "development")

    expect(result.answer.status).to eq(:no_results)
    expect(result.answer.text).to be_nil
    expect(result.suggestions).to eq(empty.suggestions)
    expect(Rag::Answer).not_to have_received(:call)
  end

  it "przy braku wyników oddaje głos rozmówcy z pytaniem oryginalnym i historią" do
    reply = Rag::Conversation::Result.new(text: "Cześć! O co chcesz zapytać?", suggestions: [])
    allow(Rag::QuestionRewriter).to receive(:call).and_return("Co słychać u asystenta?")
    allow(Rag::Search).to receive(:call).and_return(empty)
    allow(Rag::Conversation).to receive(:call).and_return(reply)

    result = described_class.call("a co słychać?", history: ["siemanko"], env: "development")

    expect(result.answer.status).to eq(:no_results)
    expect(result.answer.text).to eq("Cześć! O co chcesz zapytać?")
    expect(result.suggestions).to eq([])
    expect(Rag::Conversation).to have_received(:call).with(
      "a co słychać?", hash_including(history: ["siemanko"], nearest: empty.suggestions)
    )
  end

  it "nie woła rozmówcy, gdy wyszukiwanie coś znalazło" do
    allow(Rag::Search).to receive(:call).and_return(found)
    allow(Rag::Conversation).to receive(:call)

    result = described_class.call("jak dodać klienta?", history: [], env: "development")

    expect(result.suggestions).to eq([])
    expect(Rag::Conversation).not_to have_received(:call)
  end

  describe ".resolve_question" do
    it "zwraca nil, gdy historia jest pusta lub niepoprawna" do
      allow(Rag::QuestionRewriter).to receive(:call)

      expect(described_class.resolve_question("a jak to?", history: [], env: "development")).to be_nil
      expect(described_class.resolve_question("a jak to?", history: "nie tablica", env: "development")).to be_nil
      expect(Rag::QuestionRewriter).not_to have_received(:call)
    end

    it "przekazuje do przepisywania historię po normalizacji" do
      allow(Rag::QuestionRewriter).to receive(:call).and_return("Samodzielne pytanie?")
      many = (1..8).map { |i| "pytanie #{i}" }

      described_class.resolve_question("a jak to?", history: many, env: "development")

      expect(Rag::QuestionRewriter).to have_received(:call).with(
        "a jak to?", hash_including(history: %w[pytanie\ 4 pytanie\ 5 pytanie\ 6 pytanie\ 7 pytanie\ 8])
      )
    end
  end
end
