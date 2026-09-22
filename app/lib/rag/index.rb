# frozen_string_literal: true

require "digest"

module Rag
  # Indeks wektorowy w Redis.
  # https://redis.io/docs/latest/develop/ai/search-and-query/vectors/
  module Index
    NAME = "idx:docs"
    PREFIX = "rag:chunk:"
    CHECKSUMS_KEY = "rag:checksums"
    # bge-m3 zwraca wektory 1024-wymiarowe. Zmiana modelu => zmiana DIM + rake rag:reindex.
    DIM = Integer(ENV.fetch("RAG_EMBEDDING_DIM", "1024"))

    module_function

    def exists?
      Rag.redis.call("FT._LIST").include?(NAME)
    end

    # FLAT = wyszukiwanie dokładne; dokumentacja Redis wskazuje FLAT dla zbiorów < 1M wektorów.
    # Zmiana schematu => rake rag:reindex.
    def create!
      return if exists?

      Rag.redis.call(
        "FT.CREATE", NAME, "ON", "HASH", "PREFIX", "1", PREFIX,
        "SCHEMA",
        "source", "TAG",
        "title", "TEXT",
        "heading", "TEXT",
        "content", "TEXT",
        "embedding", "VECTOR", "FLAT", "6",
        "TYPE", "FLOAT32", "DIM", DIM.to_s, "DISTANCE_METRIC", "COSINE"
      )
    end

    # DD usuwa również klucze z danymi.
    def drop!
      Rag.redis.call("FT.DROPINDEX", NAME, "DD") if exists?
      Rag.redis.del(CHECKSUMS_KEY)
    end

    # Stabilny identyfikator pliku: używany w kluczach Redis i w URL instrukcji.
    def id_for(source)
      Digest::SHA1.hexdigest(source)[0, 16]
    end

    def key_prefix_for(source)
      "#{PREFIX}#{id_for(source)}:"
    end

    def delete_source(source)
      keys = Rag.redis.scan_each(match: "#{key_prefix_for(source)}*").to_a
      Rag.redis.del(*keys) unless keys.empty?
    end

    # FLOAT32 little-endian: format bajtów wektora w polu HASH.
    def pack(vector)
      vector.pack("e*")
    end
  end
end
