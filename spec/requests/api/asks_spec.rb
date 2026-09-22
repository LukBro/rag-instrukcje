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

  it "zwraca 503 gdy Ollama zgłasza błąd" do
    allow(Rag::Search).to receive(:call).and_raise(Rag::OllamaClient::Error, "timeout")

    post "/api/ask", params: { question: "Jak?" }, as: :json

    expect(response).to have_http_status(:service_unavailable)
  end
end
