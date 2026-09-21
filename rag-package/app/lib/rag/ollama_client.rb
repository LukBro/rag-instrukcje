# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rag
  # Minimalny klient endpointu embeddingów Ollama (bez dodatkowych gemów).
  # https://docs.ollama.com/api/embed.md
  class OllamaClient
    Error = Class.new(StandardError)

    def initialize(base_url:, read_timeout: 120, open_timeout: 5)
      @base_url = base_url
      @read_timeout = read_timeout
      @open_timeout = open_timeout
    end

    # Zwraca tablicę wektorów w kolejności wejścia.
    # truncate: false -> błąd zamiast cichego obcięcia tekstu dłuższego niż okno modelu
    # (domyślna wartość w Ollama to true).
    # keep_alive: nil -> obowiązuje OLLAMA_KEEP_ALIVE ustawione na serwerze Ollama.
    def embed(model:, input:, keep_alive: nil)
      body = { model: model, input: input, truncate: false }
      body[:keep_alive] = keep_alive if keep_alive
      post("/api/embed", body).fetch("embeddings")
    end

    private

    def post(path, body)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout,
                                 read_timeout: @read_timeout) { |http| http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Ollama #{path} HTTP #{response.code}: #{response.body.to_s[0, 500]}"
      end

      JSON.parse(response.body)
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
      raise Error, "Ollama #{path}: #{e.class}: #{e.message}"
    end
  end
end
