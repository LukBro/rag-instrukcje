# frozen_string_literal: true

module Rag
  # Przepisuje pytanie doprecyzowujące ("a jak to usunąć?") na samodzielne, na podstawie
  # poprzednich pytań użytkownika. Wołane tylko jako fallback, gdy Search nic nie znalazło:
  # to dodatkowe wywołanie Gemini, a zmierzony ogon latencji dochodził do 161 s (BRO-72).
  class QuestionRewriter
    MODEL = ENV.fetch("RAG_GEMINI_REWRITE_MODEL", Answer::MODEL)
    # Wynikiem jest jedno zdanie; 64 tokeny wystarczają i ograniczają czas odpowiedzi.
    MAX_OUTPUT_TOKENS = Integer(ENV.fetch("RAG_GEMINI_REWRITE_MAX_OUTPUT_TOKENS", "64"))
    # Krótszy timeout i jedno ponowienie (Answer ma 90 s i dwa): wywołanie na kilkadziesiąt
    # tokenów albo odpowiada szybko, albo nie warto na nie czekać.
    TIMEOUT = Integer(ENV.fetch("RAG_GEMINI_REWRITE_TIMEOUT", "15"))
    MAX_RETRIES = 1
    # Ile ostatnich pytań i ile znaków każde trafia do modelu.
    MAX_HISTORY = Integer(ENV.fetch("RAG_HISTORY_TURNS", "5"))
    MAX_QUESTION_CHARS = Integer(ENV.fetch("RAG_HISTORY_QUESTION_CHARS", "500"))

    SYSTEM_PROMPT = <<~PROMPT
      Na podstawie poprzednich pytań użytkownika przepisz jego ostatnie pytanie tak, aby było zrozumiałe bez znajomości rozmowy.
      Zasady:
      1. Zastąp zaimki i skróty ("to", "tego", "a jak") nazwami z poprzednich pytań.
      2. Nie dopisuj informacji, których nie ma w pytaniach użytkownika.
      3. Jeśli ostatnie pytanie jest już samodzielne, przepisz je bez zmian.
      4. Odpowiedz samym pytaniem, po polsku, w jednym zdaniu. Bez komentarza i bez cudzysłowów.
    PROMPT

    def self.default_client
      GeminiClient.new(
        api_key: Answer.api_key,
        base_url: ENV.fetch("RAG_GEMINI_BASE_URL", GeminiClient::BASE_URL),
        read_timeout: TIMEOUT,
        max_retries: MAX_RETRIES
      )
    end

    # Zwraca samodzielne pytanie albo nil (brak historii, Gemini wyłączone, błąd, pusta odpowiedź,
    # pytanie bez zmian). nil oznacza "brak przepisania" i prowadzi do zachowania sprzed BRO-72.
    def self.call(question, history:, env:, client: nil, logger: nil)
      question = question.to_s.strip
      turns = normalize(history)
      return nil if question.empty? || turns.empty?
      return nil unless Answer.enabled?(env: env)

      response = (client || default_client).generate(
        model: MODEL,
        system_instruction: SYSTEM_PROMPT,
        user_text: user_message(question, turns),
        max_output_tokens: MAX_OUTPUT_TOKENS,
        thinking_level: Answer::THINKING_LEVEL
      )
      rewritten = response.text.to_s.strip.delete_prefix('"').delete_suffix('"').strip
      return nil if rewritten.empty? || rewritten.casecmp?(question)

      rewritten
    rescue GeminiClient::Error => e
      logger&.warn("[rag] przepisanie pytania nieudane: #{e.message}")
      nil
    end

    # Historia z żądania HTTP jest niezaufana: bierzemy tylko niepuste stringi, ostatnie MAX_HISTORY,
    # każdy obcięty do MAX_QUESTION_CHARS. Cokolwiek innego traktujemy jak brak historii.
    def self.normalize(history)
      return [] unless history.is_a?(Array)

      history.filter_map { |q| q.to_s.strip.presence&.slice(0, MAX_QUESTION_CHARS) if q.is_a?(String) }
             .last(MAX_HISTORY)
    end

    def self.user_message(question, turns)
      previous = turns.each_with_index.map { |q, i| "#{i + 1}. #{q}" }.join("\n")

      "Poprzednie pytania użytkownika:\n#{previous}\n\nOstatnie pytanie: #{question}"
    end
  end
end
