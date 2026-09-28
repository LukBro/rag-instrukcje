# frozen_string_literal: true

module Rag
  # Jedno żądanie /api/ask: ustalenie samodzielnego pytania (gdy klient przysłał historię),
  # wyszukanie i odpowiedź.
  #
  # BRO-72: przepisywanie NIE jest uzależnione od braku wyników. Pytanie doprecyzowujące
  # ("a jak to usunąć?") zwykle trafia w losową instrukcję zawierającą to samo słowo - zmierzone
  # 0,3803, czyli poniżej progu 0,45 - więc warunek "brak wyników" nigdy by się nie spełnił.
  # Decyzję, czy pytanie wymaga kontekstu, podejmuje QuestionRewriter: dla pytań samodzielnych
  # zwraca nil i wtedy nic się nie zmienia.
  class Ask
    # rewritten_question: wypełnione tylko wtedy, gdy pytanie zostało przepisane (do logu, nie do API).
    Result = Struct.new(:answer, :search_result, :rewritten_question, keyword_init: true)

    def self.call(question, history: [], env: Rails.env, logger: nil)
      question = question.to_s.strip
      rewritten = resolve_question(question, history: history, env: env, logger: logger)
      effective = rewritten || question

      search_result = Search.call(effective)
      answer = if search_result.found?
                 Answer.call(effective, env: env, search_result: search_result, logger: logger)
               else
                 Answer::Result.new(status: :no_results, sources: [])
               end

      Result.new(answer: answer, search_result: search_result, rewritten_question: rewritten)
    end

    # Samodzielne pytanie albo nil, gdy nie ma historii lub przepisanie nie było potrzebne/możliwe.
    # Używane też przez rake rag:eval, żeby ewaluacja szła tą samą ścieżką co API.
    def self.resolve_question(question, history:, env:, logger: nil)
      turns = QuestionRewriter.normalize(history)
      return nil if turns.empty?

      rewritten = QuestionRewriter.call(question, history: turns, env: env, logger: logger)
      logger&.info("[rag] pytanie przepisane: #{question.inspect} -> #{rewritten.inspect}") if rewritten
      rewritten
    end
  end
end
