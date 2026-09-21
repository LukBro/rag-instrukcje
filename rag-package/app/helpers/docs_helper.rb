# frozen_string_literal: true

module DocsHelper
  # escape_html: true - surowy HTML w plikach Markdown jest escapowany, nie renderowany.
  def doc_markdown(text)
    @doc_markdown_renderer ||= Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: true),
      fenced_code_blocks: true, tables: true
    )
    @doc_markdown_renderer.render(text.to_s).html_safe # rubocop:disable Rails/OutputSafety
  end

  # "Tytuł › Sekcja" -> "Sekcja"; dla instrukcji w jednym fragmencie -> nil
  def doc_section(heading)
    heading.to_s.split(Rag::MarkdownChunker::SEPARATOR, 2)[1]
  end
end
