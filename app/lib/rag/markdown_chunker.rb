# frozen_string_literal: true

require "date"
require "yaml"

module Rag
  # Dzieli plik Markdown na fragmenty do wektoryzacji.
  #
  # Reguły (decyzje projektowe, do weryfikacji przez rake rag:eval):
  # 1. Dokument <= MAX_CHARS -> jeden fragment (cała instrukcja: wymagania, kroki, wynik).
  # 2. Dłuższy dokument -> podział po nagłówkach "## " (poza blokami kodu).
  # 3. Sekcja > MAX_CHARS -> podział po akapitach z zakładką (ostatni akapit <= OVERLAP_CHARS).
  # 4. Tekst do wektoryzacji (embed_text) = ścieżka nagłówków + pytania z front matter
  #    (tylko pierwszy fragment) + treść. Tekst do wyświetlenia (text) = sama treść.
  class MarkdownChunker
    MAX_CHARS = Integer(ENV.fetch("RAG_CHUNK_MAX_CHARS", "1500"))
    OVERLAP_CHARS = Integer(ENV.fetch("RAG_CHUNK_OVERLAP_CHARS", "300"))
    SEPARATOR = " › "

    Chunk = Struct.new(:heading, :text, :embed_text, keyword_init: true)
    Parsed = Struct.new(:title, :front_matter, :questions, :body, keyword_init: true)
    Result = Struct.new(:title, :front_matter, :chunks, keyword_init: true)

    def self.parse(markdown, fallback_title:)
      new(markdown, fallback_title).parse
    end

    def self.call(markdown, fallback_title:)
      new(markdown, fallback_title).call
    end

    def initialize(markdown, fallback_title)
      @markdown = markdown.to_s.gsub("\r\n", "\n")
      @fallback_title = fallback_title
    end

    def parse
      front_matter, body = split_front_matter(@markdown)
      title, body = extract_title(front_matter, body)
      questions = Array(front_matter["questions"]).map { |q| q.to_s.strip }.reject(&:empty?)
      Parsed.new(title: title, front_matter: front_matter, questions: questions, body: body)
    end

    def call
      parsed = parse
      body = parsed.body

      pieces =
        if body.strip.length <= MAX_CHARS
          body.strip.empty? ? [] : [[parsed.title, body]]
        else
          split_sections(body).flat_map do |heading, section_body|
            split_long(section_body).map { |part| [join_heading(parsed.title, heading), part] }
          end
        end

      chunks = pieces.each_with_index.map do |(heading, text), i|
        build_chunk(heading, text, i.zero? ? parsed.questions : [])
      end

      Result.new(title: parsed.title, front_matter: parsed.front_matter, chunks: chunks)
    end

    private

    def split_front_matter(text)
      return [{}, text] unless text.start_with?("---\n")

      closing = text.index("\n---\n", 4)
      return [{}, text] unless closing

      data = YAML.safe_load(text[4...closing], permitted_classes: [Date]) || {}
      [data, text[(closing + 5)..]]
    end

    def extract_title(front_matter, body)
      lines = body.lines
      h1_index = lines.index { |l| l.start_with?("# ") }
      h1 = h1_index && lines[h1_index].sub(/\A# /, "").strip
      lines.delete_at(h1_index) if h1_index

      title = front_matter["title"].to_s.strip
      title = h1.to_s if title.empty?
      title = @fallback_title if title.empty?
      [title, lines.join]
    end

    # Zwraca [[nagłówek_h2_lub_nil, treść], ...]
    def split_sections(body)
      sections = [[nil, +""]]
      in_fence = false

      body.each_line do |line|
        in_fence = !in_fence if line.start_with?("```", "~~~")

        if !in_fence && line.start_with?("## ")
          sections << [line.sub(/\A## /, "").strip, +""]
        else
          sections.last[1] << line
        end
      end

      sections.reject { |_, text| text.strip.empty? }
    end

    def split_long(text)
      text = text.strip
      return [text] if text.length <= MAX_CHARS

      parts = []
      current = []

      paragraphs(text).each do |para|
        if para.length > MAX_CHARS
          parts << current.join("\n\n") unless current.empty?
          current = []
          parts.concat(hard_split(para))
          next
        end

        candidate = (current + [para]).join("\n\n")
        if candidate.length > MAX_CHARS && !current.empty?
          parts << current.join("\n\n")
          overlap = current.last.length <= OVERLAP_CHARS ? [current.last] : []
          current = overlap + [para]
        else
          current << para
        end
      end

      parts << current.join("\n\n") unless current.empty?
      parts
    end

    def paragraphs(text)
      text.split(/\n{2,}/).map(&:strip).reject(&:empty?)
    end

    def hard_split(text)
      step = MAX_CHARS - OVERLAP_CHARS
      starts = (0...text.length).step(step).select { |i| i.zero? || i + OVERLAP_CHARS < text.length }
      starts.map { |i| text[i, MAX_CHARS] }
    end

    def join_heading(title, heading)
      heading ? "#{title}#{SEPARATOR}#{heading}" : title
    end

    def build_chunk(heading, text, questions)
      body = text.strip
      parts = [heading]
      parts << "Pytania: #{questions.join(' ')}" unless questions.empty?
      parts << body
      Chunk.new(heading: heading, text: body, embed_text: parts.join("\n\n"))
    end
  end
end
