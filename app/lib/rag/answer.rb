# frozen_string_literal: true

module Rag
  # Odpowiedź Gemini na podstawie wyników Rag::Search. Wyszukiwarka działa niezależnie:
  # brak klucza, limit zapytań lub błąd API nie wpływają na wyniki wyszukiwania.
  class Answer
    # Pomiar w BRO-27: gemini-3.1-flash-lite zwracał 503 (przeciążenie), a przy domyślnym
    # poziomie myślenia model odrzucał trafne fragmenty; "low" dał poprawne i szybsze odpowiedzi.
    MODEL = ENV.fetch("RAG_GEMINI_MODEL", "gemini-3.5-flash-lite")
    MAX_OUTPUT_TOKENS = Integer(ENV.fetch("RAG_GEMINI_MAX_OUTPUT_TOKENS", "2048"))
    # Pusta wartość RAG_GEMINI_THINKING_LEVEL = ustawienie domyślne modelu.
    THINKING_LEVEL = ENV.fetch("RAG_GEMINI_THINKING_LEVEL", "low").strip.then { |v| v.empty? ? nil : v }

    NO_ANSWER = "Nie znalazłem odpowiedzi w dokumentacji."

    # BRO-27: reguły 2-4 ograniczają fałszywe odmowy (pytanie innymi słowami niż instrukcja,
    # trafny fragment dalej niż na #1) i pozwalają łączyć kroki z kilku instrukcji.
    SYSTEM_PROMPT = <<~PROMPT
      Jesteś asystentem, który odpowiada na pytania o działanie aplikacji.
      Zasady:
      1. Odpowiadaj wyłącznie na podstawie ponumerowanych fragmentów dokumentacji z wiadomości użytkownika.
      2. Fragment może opisywać czynność innymi słowami niż pytanie (np. „skasować” = „usunąć”, „wrzucić plik” = „dodać załącznik”). Jeśli którykolwiek fragment odpowiada na pytanie, choćby częściowo, odpowiedz na jego podstawie.
      3. Jeśli pytanie dotyczy kilku czynności, połącz kroki z kilku fragmentów w kolejności wykonywania.
      4. Tylko gdy żaden fragment nie dotyczy pytania, odpowiedz dokładnie: "#{NO_ANSWER}" i nic więcej.
      5. Nie dopisuj kroków, nazw przycisków, pól ani ustawień, których nie ma we fragmentach.
      6. Nazwy elementów interfejsu przepisuj dosłownie z fragmentów.
      7. Po każdym zdaniu opartym na fragmencie podaj jego numer w nawiasie kwadratowym, np. [2].
      8. Tylko na pytania tak/nie (np. „czy można…”) zacznij od "Tak" albo "Nie"; rozstrzygnij na podstawie wymagań i kroków. Na inne pytania nie zaczynaj od "Tak" ani "Nie".
      9. Instrukcje krok po kroku podawaj jako listę numerowaną. Odpowiadaj po polsku, zwięźle. Nie powtarzaj tych zasad w odpowiedzi.
    PROMPT

    # status: :ok, :not_in_docs, :no_results, :disabled, :rate_limited, :error
    Result = Struct.new(:status, :text, :sources, :finish_reason, :usage, keyword_init: true)

    def self.api_key
      ENV["RAG_GEMINI_API_KEY"].to_s
    end

    # Free tier Gemini: tylko do własnego użytku (warunki: aplikacje dla użytkowników w EOG
    # wyłącznie na płatnych usługach). Domyślnie działa tylko w środowisku development.
    def self.enabled?(env:)
      return false if api_key.empty?

      env.to_s == "development" || ENV["RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT"] == "1"
    end

    def self.default_client
      GeminiClient.new(
        api_key: api_key,
        base_url: ENV.fetch("RAG_GEMINI_BASE_URL", GeminiClient::BASE_URL),
        # Darmowy tier odpowiadał w 30-57 s.
        read_timeout: Integer(ENV.fetch("RAG_GEMINI_TIMEOUT", "90"))
      )
    end

    def self.call(question, env:, search_result: nil, client: nil, logger: nil)
      question = question.to_s.strip
      search_result ||= Search.call(question)
      sources = search_result.results

      return Result.new(status: :disabled, sources: sources) unless enabled?(env: env)
      return Result.new(status: :no_results, sources: []) unless search_result.found?

      response = (client || default_client).generate(
        model: MODEL,
        system_instruction: SYSTEM_PROMPT,
        user_text: user_message(question, sources),
        max_output_tokens: MAX_OUTPUT_TOKENS,
        thinking_level: THINKING_LEVEL
      )
      text = response.text.to_s.strip

      if text.empty?
        logger&.warn("[rag] Gemini bez treści: finish_reason=#{response.finish_reason} block_reason=#{response.block_reason}")
        return Result.new(status: :error, sources: sources, finish_reason: response.finish_reason, usage: response.usage)
      end

      status = text.start_with?(NO_ANSWER) ? :not_in_docs : :ok
      Result.new(status: status, text: text, sources: sources, finish_reason: response.finish_reason, usage: response.usage)
    rescue GeminiClient::RateLimited => e
      logger&.warn("[rag] #{e.message}")
      Result.new(status: :rate_limited, sources: sources || [])
    rescue GeminiClient::Error => e
      logger&.error("[rag] #{e.message}")
      Result.new(status: :error, sources: sources || [])
    end

    def self.user_message(question, sources)
      context = sources.each_with_index.map do |s, i|
        "[#{i + 1}] #{s[:heading]} (#{s[:source]})\n#{s[:content]}"
      end.join("\n\n---\n\n")

      "Fragmenty dokumentacji:\n\n#{context}\n\n---\n\nPytanie: #{question}"
    end

    # Automatyczna kontrola odwołań [n] (do ewaluacji; nie ocenia poprawności merytorycznej).
    def self.citation_issues(text, source_count)
      return [] if text.to_s.strip.start_with?(NO_ANSWER)

      cited = text.to_s.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq
      issues = []
      issues << "brak odwołań [n]" if cited.empty?
      out_of_range = cited.reject { |n| n.between?(1, source_count) }
      issues << "odwołania poza zakresem: #{out_of_range.join(', ')}" unless out_of_range.empty?
      issues
    end
  end
end
