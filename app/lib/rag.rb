# frozen_string_literal: true

require "redis"

# Punkt dostępu do zależności (zamiast stałych w config/initializers:
# Rails 7 nie wspiera autoloadowania przeładowywalnych stałych podczas inicjalizacji).
module Rag
  def self.redis
    # Redis z modułem wyszukiwania (Redis 8+ lub Redis Stack), baza 0.
    @redis ||= Redis.new(url: ENV.fetch("RAG_REDIS_URL", "redis://localhost:6379/0"))
  end

  def self.ollama
    # Ollama służy wyłącznie do embeddingów (bge-m3).
    @ollama ||= OllamaClient.new(
      base_url: ENV.fetch("OLLAMA_URL", "http://localhost:11434"),
      read_timeout: Integer(ENV.fetch("RAG_OLLAMA_TIMEOUT", "120"))
    )
  end
end
