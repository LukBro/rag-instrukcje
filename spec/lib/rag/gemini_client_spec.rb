require "rails_helper"

RSpec.describe Rag::GeminiClient do
  OK_BODY = JSON.generate({
    "candidates" => [{ "content" => { "role" => "model", "parts" => [
      { "text" => "myślenie", "thought" => true }, { "text" => "Kliknij " }, { "text" => "Koryguj [1]." }
    ] }, "finishReason" => "STOP" }],
    "usageMetadata" => { "promptTokenCount" => 1200, "candidatesTokenCount" => 20 }
  })

  it "buduje żądanie i parsuje odpowiedź" do
    server = FakeHttpServer.new([["200 OK", OK_BODY]])
    client = described_class.new(api_key: "SEKRET", base_url: server.url)
    r = client.generate(model: "gemini-3.1-flash-lite", system_instruction: "SYS", user_text: "PYT",
                        max_output_tokens: 512, thinking_level: "low")
    server.join
    req = server.requests.first
    expect(req[:line]).to match(%r{\APOST /v1beta/models/gemini-3.1-flash-lite:generateContent HTTP})
    expect(req[:line]).not_to include("SEKRET")
    expect(req[:headers]["x-goog-api-key"]).to eq("SEKRET")
    expect(req[:body].dig("systemInstruction", "parts", 0, "text")).to eq("SYS")
    expect(req[:body].dig("contents", 0, "parts", 0, "text")).to eq("PYT")
    expect(req[:body].dig("contents", 0, "role")).to eq("user")
    expect(req[:body].dig("generationConfig", "maxOutputTokens")).to eq(512)
    expect(req[:body].dig("generationConfig", "thinkingConfig", "thinkingLevel")).to eq("low")
    expect(req[:body]["generationConfig"]).not_to have_key("temperature")
    expect(r.text).to eq("Kliknij Koryguj [1].")
    expect(r.finish_reason).to eq("STOP")
    expect(r.usage["promptTokenCount"]).to eq(1200)
  ensure
    server&.close
  end

  it "pomija thinkingConfig, gdy poziom jest nil" do
    server = FakeHttpServer.new([["200 OK", OK_BODY]])
    described_class.new(api_key: "k", base_url: server.url)
                   .generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    server.join
    expect(server.requests.first[:body]["generationConfig"]).not_to have_key("thinkingConfig")
  ensure
    server&.close
  end

  it "ponawia 429 i w końcu zgłasza RateLimited" do
    err = '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}'
    server = FakeHttpServer.new([["429 Too Many Requests", err]] * 3)
    sleeps = []
    client = described_class.new(api_key: "k", base_url: server.url, max_retries: 2, sleeper: ->(s) { sleeps << s })
    expect do
      client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    end.to raise_error(Rag::GeminiClient::RateLimited)
    server.join
    expect(server.requests.size).to eq(3)
    expect(sleeps).to eq([1, 2])
  ensure
    server&.close
  end

  it "ponawia po 503 i zwraca sukces" do
    server = FakeHttpServer.new([["503 Service Unavailable", "{}"], ["200 OK", OK_BODY]])
    client = described_class.new(api_key: "k", base_url: server.url, sleeper: ->(_) {})
    r = client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    server.join
    expect(r.text).to eq("Kliknij Koryguj [1].")
  ensure
    server&.close
  end

  it "nie ponawia 400" do
    server = FakeHttpServer.new([["400 Bad Request", '{"error":{"status":"FAILED_PRECONDITION"}}']])
    client = described_class.new(api_key: "k", base_url: server.url, sleeper: ->(_) { raise "nie ponawiać 400" })
    expect do
      client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    end.to raise_error(Rag::GeminiClient::Error) do |e|
      expect(e).not_to be_a(Rag::GeminiClient::RetryableError)
      expect(e.message).to match(/FAILED_PRECONDITION/)
    end
    server.join
  ensure
    server&.close
  end

  it "odrzuca niepoprawną nazwę modelu i brak klucza" do
    expect { described_class.new(api_key: "") }.to raise_error(ArgumentError)
    c = described_class.new(api_key: "k", base_url: "http://127.0.0.1:1")
    expect { c.generate(model: "../x", system_instruction: "s", user_text: "u", max_output_tokens: 1) }
      .to raise_error(ArgumentError)
  end
end
