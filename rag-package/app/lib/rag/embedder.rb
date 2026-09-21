# frozen_string_literal: true

module Rag
  class Embedder
    MODEL = ENV.fetch("RAG_EMBEDDING_MODEL", "bge-m3")
    BATCH_SIZE = Integer(ENV.fetch("RAG_EMBEDDING_BATCH", "16"))
    KEEP_ALIVE = ENV["RAG_KEEP_ALIVE"] # nil = ustawienie serwera Ollama (zalecane OLLAMA_KEEP_ALIVE=-1)

    def self.call(texts)
      texts.each_slice(BATCH_SIZE).flat_map do |batch|
        vectors = Rag.ollama.embed(model: MODEL, input: batch, keep_alive: KEEP_ALIVE)

        if vectors.size != batch.size
          raise OllamaClient::Error, "Oczekiwano #{batch.size} wektorów, otrzymano #{vectors.size}"
        end

        vectors.each do |vector|
          next if vector.size == Index::DIM

          raise OllamaClient::Error,
                "Wymiar #{vector.size} != Index::DIM #{Index::DIM}. Sprawdź RAG_EMBEDDING_MODEL i RAG_EMBEDDING_DIM."
        end

        vectors
      end
    end
  end
end
