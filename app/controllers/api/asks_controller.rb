# frozen_string_literal: true

module Api
  class AsksController < ApplicationController
    STATUS_HTTP = {
      ok: :ok,
      not_in_docs: :ok,
      no_results: :ok,
      disabled: :ok,
      rate_limited: :too_many_requests,
      error: :service_unavailable
    }.freeze

    def create
      question = params[:question]
      return render json: { error: "question jest wymagane" }, status: :bad_request if question.blank?

      # history: poprzednie pytania użytkownika; puste = zachowanie sprzed BRO-72.
      ask = Rag::Ask.call(question, history: params[:history], env: Rails.env, logger: Rails.logger)

      render json: ask_response(ask.answer, ask.search_result), status: STATUS_HTTP.fetch(ask.answer.status)
    rescue Rag::OllamaClient::Error, Redis::BaseError => e
      Rails.logger.error("[api/ask] #{e.class}: #{e.message}")
      render json: ask_response(Rag::Answer::Result.new(status: :error, sources: []), nil), status: :service_unavailable
    end

    private

    def ask_response(result, search_result)
      {
        status: result.status.to_s,
        answer: result.text,
        finish_reason: result.finish_reason,
        sources: Array(result.sources).each_with_index.map { |source, i| source_json(source, i) },
        suggestions: result.status == :no_results ? Array(search_result&.suggestions) : []
      }
    end

    def source_json(source, index)
      {
        n: index + 1,
        source: source[:source],
        title: source[:title],
        heading: source[:heading],
        content: source[:content],
        distance: source[:distance]
      }
    end
  end
end
