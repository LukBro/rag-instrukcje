# frozen_string_literal: true

# GET /pomoc/odpowiedz?q=... - odpowiedź Gemini ładowana osobno od wyników wyszukiwania
# (Turbo Frame w search/index). Bez Turbo działa jako zwykła strona po kliknięciu linku.
class AnswersController < ApplicationController
  def show
    @question = params[:q].to_s.strip
    return head(:bad_request) if @question.empty?

    begin
      @answer = Rag::Answer.call(@question, env: Rails.env, logger: Rails.logger)
    rescue Rag::OllamaClient::Error, Redis::BaseError => e
      Rails.logger.error("[rag] #{e.class}: #{e.message}")
      @answer = nil
    end
  end
end
