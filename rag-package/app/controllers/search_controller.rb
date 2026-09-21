# frozen_string_literal: true

# GET /pomoc?q=...  (HTML lub JSON: /pomoc.json?q=...)
# GET pozwala linkować wyniki i nie wymaga tokenu CSRF.
class SearchController < ApplicationController
  def index
    @question = params[:q].to_s.strip

    begin
      @result = Rag::Search.call(@question) unless @question.empty?
    rescue Rag::OllamaClient::Error, Redis::BaseError => e
      Rails.logger.error("[rag] #{e.class}: #{e.message}")
      @error = "Wyszukiwarka jest chwilowo niedostępna."
    end

    status = @error ? :service_unavailable : :ok
    respond_to do |format|
      format.html { render :index, status: status }
      format.json do
        if @error
          render json: { error: @error }, status: status
        else
          render json: (@result&.to_h || { results: [], suggestions: [] })
        end
      end
    end
  end
end
