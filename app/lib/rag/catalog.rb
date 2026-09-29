# frozen_string_literal: true

module Rag
  # Tytuły wszystkich zaindeksowanych instrukcji - dla rozmówcy, który nie widzi ich treści (BRO-73).
  module Catalog
    Entry = Struct.new(:source, :title, keyword_init: true)
    LIMIT = 1000

    module_function

    def call
      raw = Rag.redis.call("FT.SEARCH", Index::NAME, "*", "RETURN", "2", "source", "title",
                           "LIMIT", "0", LIMIT.to_s, "DIALECT", "2")
      parse(raw)
    end

    # RESP2 jak w Retriever: [liczba, klucz, [pole, wartość, ...], ...]. Plik może mieć kilka fragmentów.
    def parse(raw)
      Array(raw).drop(1).each_slice(2).map do |_key, fields|
        h = fields.each_slice(2).to_h
        Entry.new(source: Retriever.utf8(h["source"]), title: Retriever.utf8(h["title"]))
      end.uniq(&:source).sort_by(&:title)
    end
  end
end
