# frozen_string_literal: true

module Rag
  # Jedno żądanie /api/ask: wyszukanie, opcjonalne przepisanie pytania doprecyzowującego
  # i odpowiedź. Przepisanie jest fallbackiem - w typowej turze nie kosztuje nic (BRO-72).
  class Ask
    # rewritten_question: wypełnione tylko wtedy, gdy fallback się udał (do logu, nie do API).
    Result = Struct.new(:answer, :search_result, :rewritten_question, keyword_init: true)

    def self.call(question, history: [], env: Rails.env, logger: nil)
      question = question.to_s.strip
      search_result = Search.call(question)

      if search_result.found?
        return Result.new(answer: answer_for(question, search_result, env, logger), search_result: search_result)
      end

      turns = QuestionRewriter.normalize(history)
      return Result.new(answer: no_results, search_result: search_result) if turns.empty?

      rewritten = QuestionRewriter.call(question, history: turns, env: env, logger: logger)
      return Result.new(answer: no_results, search_result: search_result) if rewritten.nil?

      logger&.info("[rag] pytanie przepisane: #{question.inspect} -> #{rewritten.inspect}")
      retried = Search.call(rewritten)
      unless retried.found?
        # Podpowiedzi z pierwszego wyszukiwania dotyczą pytania, które zadał użytkownik.
        return Result.new(answer: no_results, search_result: search_result, rewritten_question: rewritten)
      end

      Result.new(answer: answer_for(rewritten, retried, env, logger), search_result: retried,
                 rewritten_question: rewritten)
    end

    def self.answer_for(question, search_result, env, logger)
      Answer.call(question, env: env, search_result: search_result, logger: logger)
    end

    # Podpowiedzi bierze kontroler z search_result, tak jak przed BRO-72.
    def self.no_results
      Answer::Result.new(status: :no_results, sources: [])
    end
  end
end
