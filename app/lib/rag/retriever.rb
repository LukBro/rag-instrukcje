# frozen_string_literal: true

module Rag
  class Retriever
    def self.call(question, k:)
      vector = Embedder.call([question]).first
      raw = Rag.redis.call(
        "FT.SEARCH", Index::NAME,
        "*=>[KNN #{Integer(k)} @embedding $vec AS distance]",
        "PARAMS", "2", "vec", Index.pack(vector),
        "SORTBY", "distance", "ASC",
        "RETURN", "5", "source", "title", "heading", "content", "distance",
        # Domyślny LIMIT w FT.SEARCH to 10 - bez tego k > 10 zwróci tylko 10 wyników.
        "LIMIT", "0", Integer(k).to_s,
        "DIALECT", "2"
      )
      parse(raw)
    end

    # Format RESP2: [liczba, klucz1, [pole, wartość, ...], klucz2, [...], ...]
    # distance = dystans kosinusowy (0..2), mniejszy = bliżej.
    def self.parse(raw)
      raw.drop(1).each_slice(2).map do |key, fields|
        h = fields.each_slice(2).to_h
        {
          key: key,
          source: utf8(h["source"]),
          title: utf8(h["title"]),
          heading: utf8(h["heading"]),
          content: utf8(h["content"]),
          distance: Float(h["distance"])
        }
      end
    end

    def self.utf8(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8)
    end
  end
end
