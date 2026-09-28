require "rails_helper"

RSpec.describe "POST /api/ask", type: :request do
  let(:sources) do
    [{ source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "Treść", distance: 0.12 }]
  end
  let(:suggestions) do
    [{ source: "docs/user/b.md", title: "B", distance: 0.8 }]
  end

  def search_result(found: true)
    Rag::Search::Result.new(results: found ? sources : [], suggestions: found ? [] : suggestions)
  end

  def stub_answer(status, sources: nil, **attrs)
    allow(Rag::Answer).to receive(:call).and_return(
      Rag::Answer::Result.new(status: status, sources: sources.nil? ? self.sources : sources, **attrs)
    )
  end

  before do
    allow(Rag::Search).to receive(:call).and_return(search_result)
  end

  it "zwraca 200 i odpowiedź dla statusu ok" do
    stub_answer(:ok, text: "Tak [1].", finish_reason: "STOP")

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["status"]).to eq("ok")
    expect(body["answer"]).to eq("Tak [1].")
    expect(body["finish_reason"]).to eq("STOP")
    expect(body["sources"]).to eq(
      [{ "n" => 1, "source" => "docs/user/a.md", "title" => "A", "heading" => "A › Kroki",
         "content" => "Treść", "distance" => 0.12 }]
    )
    expect(body["suggestions"]).to eq([])
  end

  it "zwraca 200 dla not_in_docs" do
    stub_answer(:not_in_docs, text: Rag::Answer::NO_ANSWER, finish_reason: "STOP")

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("not_in_docs")
  end

  it "zwraca 200 i suggestions dla no_results" do
    allow(Rag::Search).to receive(:call).and_return(search_result(found: false))
    stub_answer(:no_results, sources: [])

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["status"]).to eq("no_results")
    expect(body["sources"]).to eq([])
    expect(body["suggestions"]).to eq([{ "source" => "docs/user/b.md", "title" => "B", "distance" => 0.8 }])
  end

  it "zwraca 200 i sources dla disabled" do
    stub_answer(:disabled)

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["status"]).to eq("disabled")
    expect(body["sources"].size).to eq(1)
    expect(body["answer"]).to be_nil
    expect(body["suggestions"]).to eq([])
  end

  it "zwraca 429 dla rate_limited" do
    stub_answer(:rate_limited)

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:too_many_requests)
    body = response.parsed_body
    expect(body["status"]).to eq("rate_limited")
    expect(body["sources"].size).to eq(1)
  end

  it "zwraca 503 dla error" do
    stub_answer(:error, sources: [])

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["status"]).to eq("error")
  end

  it "zwraca 400 dla pustego question" do
    allow(Rag::Answer).to receive(:call)

    post "/api/ask", params: { question: "" }, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(Rag::Answer).not_to have_received(:call)
  end

  it "zwraca 400 dla brakującego question" do
    post "/api/ask", params: {}, as: :json

    expect(response).to have_http_status(:bad_request)
  end

  it "zwraca 503 gdy Redis jest niedostępny" do
    allow(Rag::Search).to receive(:call).and_raise(Redis::BaseError, "connection refused")

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["status"]).to eq("error")
  end

  it "przekazuje history do Rag::Ask i zwraca odpowiedź na przepisane pytanie" do
    allow(Rag::Search).to receive(:call).with("a jak to usunąć?").and_return(search_result(found: false))
    allow(Rag::Search).to receive(:call).with("Jak usunąć adres dostawy klienta?").and_return(search_result)
    allow(Rag::QuestionRewriter).to receive(:call).and_return("Jak usunąć adres dostawy klienta?")
    stub_answer(:ok, text: "Odpowiedź", finish_reason: "STOP")

    post "/api/ask", params: { question: "a jak to usunąć?", history: ["jak dodać adres dostawy?"] }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("ok")
    expect(Rag::QuestionRewriter).to have_received(:call).with(
      "a jak to usunąć?", hash_including(history: ["jak dodać adres dostawy?"])
    )
  end

  it "bez history nie próbuje przepisywać pytania" do
    allow(Rag::Search).to receive(:call).and_return(search_result(found: false))
    allow(Rag::QuestionRewriter).to receive(:call)
    stub_answer(:no_results, sources: [])

    post "/api/ask", params: { question: "zupełnie nie z tej dokumentacji" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("no_results")
    expect(response.parsed_body["suggestions"].size).to eq(1)
    expect(Rag::QuestionRewriter).not_to have_received(:call)
  end

  it "obcina zbyt długą history zamiast zwracać błąd" do
    allow(Rag::Search).to receive(:call).and_return(search_result(found: false))
    allow(Rag::QuestionRewriter).to receive(:call).and_return(nil)

    post "/api/ask",
         params: { question: "a jak to?", history: (1..8).map { |i| "pytanie #{i}" } + ["x" * 900] },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(Rag::QuestionRewriter).to have_received(:call) do |_question, history:, **|
      expect(history.size).to eq(Rag::QuestionRewriter::MAX_HISTORY)
      expect(history.first).to eq("pytanie 5")
      expect(history.last.length).to eq(Rag::QuestionRewriter::MAX_QUESTION_CHARS)
    end
  end

  it "zwraca 503 gdy Ollama zgłasza błąd" do
    allow(Rag::Search).to receive(:call).and_raise(Rag::OllamaClient::Error, "timeout")

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:service_unavailable)
  end
end
