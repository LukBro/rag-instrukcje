# frozen_string_literal: true

module Rag
  # Wyszukiwanie instrukcji bez LLM: pytanie -> najlepsze sekcje z różnych plików.
  class Search
    # PLACEHOLDER - skalibruj przez rake rag:eval (pytania spoza zakresu z expected_sources: []).
    MAX_DISTANCE = Float(ENV.fetch("RAG_MAX_DISTANCE", "0.5"))
    # Liczba fragmentów pobieranych z Redis przed wyborem najlepszej sekcji z każdego pliku.
    CANDIDATES = Integer(ENV.fetch("RAG_CANDIDATES", "10"))
    RESULTS = Integer(ENV.fetch("RAG_RESULTS", "3"))
    SUGGESTIONS = Integer(ENV.fetch("RAG_SUGGESTIONS", "3"))

    # results: sekcje poniżej progu (pierwsza = najlepsze dopasowanie)
    # suggestions: tytuły najbliższych instrukcji, wypełniane tylko gdy results jest puste
    Result = Struct.new(:results, :suggestions, keyword_init: true) do
      def found?
        !results.empty?
      end
    end

    def self.call(question)
      question = question.to_s.strip
      return Result.new(results: [], suggestions: []) if question.empty?

      # Wyniki są posortowane rosnąco po dystansie, więc uniq zostawia najlepszą sekcję pliku.
      best_per_source = Retriever.call(question, k: CANDIDATES).uniq { |c| c[:source] }
      results = best_per_source.select { |c| c[:distance] <= MAX_DISTANCE }.first(RESULTS)
      suggestions = results.empty? ? best_per_source.first(SUGGESTIONS) : []

      Result.new(
        results: results.map { |c| c.slice(:source, :title, :heading, :content, :distance) },
        suggestions: suggestions.map { |c| c.slice(:source, :title, :distance) }
      )
    end
  end
end
