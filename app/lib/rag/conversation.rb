# frozen_string_literal: true

require "json"

module Rag
  # Odpowiedź, gdy wyszukiwarka nic nie znalazła: pogawędka, pytanie spoza instrukcji, „od czego
  # zacząć”. Model zna tylko tytuły instrukcji, nie ich treść, więc nie może podawać kroków - może
  # jedynie wskazać tematy z katalogu (BRO-73). Wołany wyłącznie na ścieżce no_results.
  class Conversation
    MODEL = ENV.fetch("RAG_GEMINI_CONVERSATION_MODEL", Answer::MODEL)
    MAX_OUTPUT_TOKENS = Integer(ENV.fetch("RAG_GEMINI_CONVERSATION_MAX_OUTPUT_TOKENS", "256"))
    # Jak w QuestionRewriter: ulepszenie, które przy niepowodzeniu degraduje się do zachowania sprzed
    # BRO-73, więc bez ponowień i z krótkim limitem czasu.
    TIMEOUT = Integer(ENV.fetch("RAG_GEMINI_CONVERSATION_TIMEOUT", "10"))
    MAX_RETRIES = 0
    MAX_TOPICS = 3

    RESPONSE_SCHEMA = {
      type: "OBJECT",
      properties: {
        reply: { type: "STRING" },
        topics: { type: "ARRAY", items: { type: "INTEGER" } }
      },
      required: %w[reply topics]
    }.freeze

    SYSTEM_PROMPT = <<~PROMPT
      Jesteś asystentem pomocy w aplikacji firmowej. Wyszukiwarka nie znalazła instrukcji pasującej do wiadomości użytkownika. Znasz tylko tytuły instrukcji z ponumerowanej listy, nie ich treść.
      Zasady:
      1. Pisz po polsku, na „Ty”, ciepło i rzeczowo, w 1-3 zdaniach, bez emoji.
      2. Nigdy nie opisuj, jak coś zrobić w aplikacji: nie podawaj kroków, przycisków, pól ani ustawień.
      3. Powitanie, podziękowanie albo pogawędka: odpowiedz krótko i zaproś do pytania o aplikację. Nie wybieraj tematów.
      4. Pytanie o to, w czym pomagasz albo od czego zacząć: w jednym zdaniu wymień główne obszary z listy instrukcji i wybierz do 3 tematów na start.
      5. Pytanie o aplikację, na które nie ma instrukcji: powiedz wprost, że nie masz instrukcji na ten temat i nie chcesz zgadywać. Wybierz do 3 tematów tylko wtedy, gdy któryś może być tym, o co chodzi.
      6. Pytanie niezwiązane z aplikacją: uprzejmie odmów i powiedz, w czym pomagasz. Nie wybieraj tematów.
      7. Wybrane tematy podaj jako numery z listy w polu topics. Nie wypisuj ich w treści odpowiedzi - użytkownik zobaczy je jako przyciski.
    PROMPT

    # suggestions: [{source:, title:, distance:}] - ten sam kształt co Search::Result#suggestions;
    # distance tylko dla tematów, które były wśród najbliższych wyników wyszukiwania.
    Result = Struct.new(:text, :suggestions, keyword_init: true)

    def self.default_client
      GeminiClient.new(
        api_key: Answer.api_key,
        base_url: ENV.fetch("RAG_GEMINI_BASE_URL", GeminiClient::BASE_URL),
        read_timeout: TIMEOUT,
        max_retries: MAX_RETRIES
      )
    end

    # nil = brak odpowiedzi rozmówcy (Gemini wyłączone, błąd, zła odpowiedź) -> no_results jak przed BRO-73.
    def self.call(message, history:, env:, catalog: nil, nearest: [], client: nil, logger: nil)
      message = message.to_s.strip
      return nil if message.empty? || !Answer.enabled?(env: env)

      catalog ||= Catalog.call
      response = (client || default_client).generate(
        model: MODEL,
        system_instruction: SYSTEM_PROMPT,
        user_text: user_message(message, QuestionRewriter.normalize(history), catalog),
        max_output_tokens: MAX_OUTPUT_TOKENS,
        thinking_level: Answer::THINKING_LEVEL,
        response_schema: RESPONSE_SCHEMA
      )
      parse(response.text, catalog, nearest, logger)
    # Redis: katalog to jedyne zapytanie po Search na tej ścieżce - jego błąd nie może zamienić
    # łagodnego no_results w 503.
    rescue GeminiClient::Error, Redis::BaseError => e
      logger&.warn("[rag] rozmówca nieudany: #{e.class}: #{e.message}")
      nil
    end

    def self.parse(text, catalog, nearest, logger)
      data = JSON.parse(text.to_s)
      reply = data.is_a?(Hash) ? data["reply"].to_s.strip : ""
      if reply.empty?
        logger&.warn("[rag] rozmówca: brak treści odpowiedzi")
        return nil
      end

      distances = nearest.to_h { |s| [s[:source], s[:distance]] }
      numbers = Array(data["topics"]).grep(Integer).select { |n| n.between?(1, catalog.size) }.uniq.first(MAX_TOPICS)
      suggestions = numbers.map do |n|
        entry = catalog[n - 1]
        { source: entry.source, title: entry.title, distance: distances[entry.source] }
      end
      Result.new(text: reply, suggestions: suggestions)
    rescue JSON::ParserError
      logger&.warn("[rag] rozmówca: odpowiedź nie jest JSON-em")
      nil
    end

    def self.user_message(message, turns, catalog)
      parts = ["Instrukcje:\n#{catalog.each_with_index.map { |e, i| "#{i + 1}. #{e.title}" }.join("\n")}"]
      parts << "Poprzednie pytania użytkownika:\n#{turns.map { |q| "- #{q}" }.join("\n")}" unless turns.empty?
      parts << "Wiadomość: #{message}"
      parts.join("\n\n")
    end
  end
end
