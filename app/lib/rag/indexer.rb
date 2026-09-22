# frozen_string_literal: true

require "digest"
require "pathname"

module Rag
  # Synchronizuje pliki Markdown z indeksem Redis.
  # Źródło prawdy: pliki w repozytorium (docs/user). Redis jest odtwarzalną kopią.
  class Indexer
    DOCS_GLOB = ENV.fetch("RAG_DOCS_GLOB", "docs/user/**/*.md")
    # Podbij przy zmianie logiki MarkdownChunker lub zapisywanych pól -> wymusza ponowną wektoryzację.
    PIPELINE_VERSION = "2"

    # Ścieżki względne plików instrukcji; pliki zaczynające się od "_" (np. szablon) są pomijane.
    def self.source_paths(root)
      root = Pathname(root)
      Dir.glob(root.join(DOCS_GLOB).to_s)
         .reject { |path| File.basename(path).start_with?("_") }
         .map { |path| Pathname(path).relative_path_from(root).to_s }
         .sort
    end

    def self.call(root:, force: false, logger: $stdout)
      new(root, force, logger).call
    end

    def initialize(root, force, logger)
      @root = Pathname(root)
      @force = force
      @logger = logger
    end

    def call
      Index.create!
      sources = self.class.source_paths(@root)
      stored = Rag.redis.hgetall(Index::CHECKSUMS_KEY)

      (stored.keys - sources).each do |source|
        Index.delete_source(source)
        Rag.redis.hdel(Index::CHECKSUMS_KEY, source)
        log "usunięto: #{source}"
      end

      sources.each do |source|
        content = File.read(@root.join(source), encoding: "UTF-8")
        checksum = Digest::SHA256.hexdigest([PIPELINE_VERSION, Embedder::MODEL, content].join("\0"))
        next if !@force && stored[source] == checksum

        count = index_source(source, content)
        Rag.redis.hset(Index::CHECKSUMS_KEY, source, checksum)
        log "zaindeksowano: #{source} (#{count} fragm.)"
      end
    end

    private

    def index_source(source, content)
      result = MarkdownChunker.call(content, fallback_title: File.basename(source, ".md"))
      # Wektoryzacja przed usunięciem starych danych: błąd Ollamy nie zostawia pliku bez indeksu.
      vectors = Embedder.call(result.chunks.map(&:embed_text))
      prefix = Index.key_prefix_for(source)

      Index.delete_source(source)
      Rag.redis.pipelined do |pipe|
        result.chunks.zip(vectors).each_with_index do |(chunk, vector), i|
          pipe.hset("#{prefix}#{i}", {
                      "source" => source,
                      "title" => result.title,
                      "heading" => chunk.heading,
                      "content" => chunk.text,
                      "embedding" => Index.pack(vector)
                    })
        end
      end

      result.chunks.size
    end

    def log(message)
      @logger&.puts("[rag] #{message}")
    end
  end
end
