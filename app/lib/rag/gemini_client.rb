# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rag
  # Minimalny klient Gemini API: POST models/{model}:generateContent (bez dodatkowych gemów).
  # https://ai.google.dev/gemini-api/docs/generate-content/text-generation
  # Klucz wysyłany w nagłówku x-goog-api-key (nie w URL, więc nie trafia do logów z adresami).
  class GeminiClient
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    Error = Class.new(StandardError)
    # Dokumentacja zaleca ponawianie z rosnącym odstępem tylko dla 429, 408 i 5xx.
    RetryableError = Class.new(Error)
    RateLimited = Class.new(RetryableError)

    Response = Struct.new(:text, :finish_reason, :block_reason, :usage, keyword_init: true)

    def initialize(api_key:, base_url: BASE_URL, read_timeout: 60, open_timeout: 5,
                   max_retries: 2, sleeper: ->(seconds) { sleep(seconds) })
      raise ArgumentError, "Brak klucza API Gemini" if api_key.to_s.empty?

      @api_key = api_key
      @base_url = base_url.chomp("/")
      @read_timeout = read_timeout
      @open_timeout = open_timeout
      @max_retries = max_retries
      @sleeper = sleeper
    end

    def generate(model:, system_instruction:, user_text:, max_output_tokens:, thinking_level: nil)
      raise ArgumentError, "Niepoprawna nazwa modelu: #{model.inspect}" unless model.to_s.match?(/\A[\w.\-]+\z/)

      generation_config = { maxOutputTokens: max_output_tokens }
      # Bez thinking_level obowiązuje domyślne ustawienie modelu (modele 3.x mają thinking domyślnie włączony).
      generation_config[:thinkingConfig] = { thinkingLevel: thinking_level } if thinking_level
      # temperature celowo nieustawiane: dokumentacja zaleca domyślne wartości dla modeli 3.x.
      body = {
        systemInstruction: { parts: [{ text: system_instruction }] },
        contents: [{ role: "user", parts: [{ text: user_text }] }],
        generationConfig: generation_config
      }

      data = with_retries { post("/models/#{model}:generateContent", body) }
      candidate = Array(data["candidates"]).first || {}
      parts = Array(candidate.dig("content", "parts"))

      Response.new(
        text: parts.reject { |p| p["thought"] }.map { |p| p["text"].to_s }.join,
        finish_reason: candidate["finishReason"],
        block_reason: data.dig("promptFeedback", "blockReason"),
        usage: data["usageMetadata"] || {}
      )
    end

    private

    def with_retries
      attempt = 0
      begin
        yield
      rescue RetryableError
        attempt += 1
        raise if attempt > @max_retries

        @sleeper.call(2**(attempt - 1)) # 1 s, 2 s, ...
        retry
      end
    end

    def post(path, body)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "x-goog-api-key" => @api_key)
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout,
                                 read_timeout: @read_timeout) { |http| http.request(request) }

      code = response.code.to_i
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      message = "Gemini HTTP #{code}: #{response.body.to_s[0, 300]}"
      raise RateLimited, message if code == 429
      raise RetryableError, message if code == 408 || code >= 500

      raise Error, message
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
      raise RetryableError, "Gemini: #{e.class}: #{e.message}"
    rescue JSON::ParserError => e
      raise Error, "Gemini: niepoprawny JSON: #{e.message}"
    end
  end
end
