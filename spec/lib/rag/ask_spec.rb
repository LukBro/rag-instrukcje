require "rails_helper"

RSpec.describe Rag::Ask do
  let(:sources) do
    [{ source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "Treść", distance: 0.12 }]
  end
  let(:found) { Rag::Search::Result.new(results: sources, suggestions: []) }
  let(:empty) do
    Rag::Search::Result.new(results: [], suggestions: [{ source: "docs/user/b.md", title: "B", distance: 0.8 }])
  end

  def answer_result(status, **attrs) = Rag::Answer::Result.new(status: status, sources: sources, **attrs)

  before do
    allow(Rag::Answer).to receive(:call).and_return(answer_result(:ok, text: "Odpowiedź"))
  end

  it "nie przepisuje pytania, gdy pierwsze wyszukiwanie coś znalazło" do
    allow(Rag::Search).to receive(:call).with("jak dodać klienta?").and_return(found)
    allow(Rag::QuestionRewriter).to receive(:call)

    result = described_class.call("jak dodać klienta?", history: ["poprzednie"], env: "development")

    expect(result.answer.status).to eq(:ok)
    expect(result.search_result).to eq(found)
    expect(Rag::QuestionRewriter).not_to have_received(:call)
    expect(Rag::Answer).to have_received(:call).with("jak dodać klienta?", hash_including(search_result: found))
  end

  it "nie przepisuje pytania bez historii" do
    allow(Rag::Search).to receive(:call).and_return(empty)
    allow(Rag::QuestionRewriter).to receive(:call)

    result = described_class.call("a jak to usunąć?", history: [], env: "development")

    expect(result.answer.status).to eq(:no_results)
    expect(result.search_result).to eq(empty)
    expect(Rag::QuestionRewriter).not_to have_received(:call)
  end

  it "przy braku wyników przepisuje pytanie i szuka ponownie" do
    allow(Rag::Search).to receive(:call).with("a jak to usunąć?").and_return(empty)
    allow(Rag::Search).to receive(:call).with("Jak usunąć adres dostawy klienta?").and_return(found)
    allow(Rag::QuestionRewriter).to receive(:call).and_return("Jak usunąć adres dostawy klienta?")

    result = described_class.call("a jak to usunąć?", history: ["jak dodać adres dostawy?"], env: "development")

    expect(result.answer.status).to eq(:ok)
    expect(result.rewritten_question).to eq("Jak usunąć adres dostawy klienta?")
    expect(Rag::Answer).to have_received(:call).with(
      "Jak usunąć adres dostawy klienta?", hash_including(search_result: found)
    )
  end

  it "zwraca no_results, gdy przepisane pytanie też nic nie znalazło" do
    allow(Rag::Search).to receive(:call).with("a jak to usunąć?").and_return(empty)
    allow(Rag::Search).to receive(:call).with("Jak usunąć fakturę?").and_return(empty)
    allow(Rag::QuestionRewriter).to receive(:call).and_return("Jak usunąć fakturę?")

    result = described_class.call("a jak to usunąć?", history: ["poprzednie"], env: "development")

    expect(result.answer.status).to eq(:no_results)
    expect(result.search_result.suggestions).to eq(empty.suggestions)
    expect(Rag::Answer).not_to have_received(:call)
  end

  it "zachowuje się jak dziś, gdy przepisanie się nie udało" do
    allow(Rag::Search).to receive(:call).with("a jak to usunąć?").and_return(empty)
    allow(Rag::QuestionRewriter).to receive(:call).and_return(nil)

    result = described_class.call("a jak to usunąć?", history: ["poprzednie"], env: "development")

    expect(result.answer.status).to eq(:no_results)
    expect(result.rewritten_question).to be_nil
    expect(Rag::Search).to have_received(:call).once
  end
end
