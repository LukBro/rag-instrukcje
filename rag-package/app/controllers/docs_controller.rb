# frozen_string_literal: true

# GET /pomoc/:id - pełna instrukcja.
# id to skrót ścieżki pliku (Rag::Index.id_for). Plik jest wyszukiwany wyłącznie
# na liście plików z docs/user, więc parametr nie może wskazać innej ścieżki na dysku.
class DocsController < ApplicationController
  def show
    source = Rag::Indexer.source_paths(Rails.root).find { |s| Rag::Index.id_for(s) == params[:id] }
    return head(:not_found) unless source

    parsed = Rag::MarkdownChunker.parse(File.read(Rails.root.join(source), encoding: "UTF-8"),
                                        fallback_title: File.basename(source, ".md"))
    @title = parsed.title
    @body = parsed.body
  end
end
