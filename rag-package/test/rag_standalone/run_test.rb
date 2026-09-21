# Uruchom z katalogu głównego: ruby -Itest/rag_standalone/stubs test/rag_standalone/run_test.rb
# Testy bez Rails, Redis i Ollama (atrapy). Wymaga Ruby >= 3.0.
require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("../..", __dir__)

%w[rag rag/ollama_client rag/gemini_client rag/index rag/embedder rag/markdown_chunker rag/indexer rag/retriever rag/search rag/answer docs_lint].each do |f|
  require File.join(ROOT, "app/lib", f)
end

class FakeRedis
  attr_reader :hashes, :calls
  attr_writer :search_result

  def initialize
    @hashes = {}
    @index = false
    @calls = []
  end

  def call(*args)
    @calls << args
    case args.first
    when "FT._LIST" then @index ? ["idx:docs"] : []
    when "FT.CREATE" then @index = true; "OK"
    when "FT.DROPINDEX" then @index = false; @hashes.clear; "OK"
    when "FT.SEARCH" then @search_result
    end
  end

  def hgetall(k) = (@hashes[k] || {}).dup
  def hset(k, *attrs)
    h = attrs.first.is_a?(Hash) ? attrs.first : attrs.each_slice(2).to_h
    (@hashes[k] ||= {}).merge!(h)
  end
  def hdel(k, f) = @hashes[k]&.delete(f)
  def del(*ks) = ks.each { |k| @hashes.delete(k) }
  def scan_each(match:) = @hashes.keys.select { |k| File.fnmatch(match, k) }.each
  def pipelined = yield(self)
end

class FakeOllama
  attr_reader :embed_calls
  def initialize = @embed_calls = []
  def embed(model:, input:, keep_alive: nil)
    @embed_calls << input
    input.map { |t| Array.new(1024) { |i| ((t.sum + i) % 7) / 7.0 } }
  end
end

def resp_row(key, source:, title:, heading:, content:, distance:)
  [key, ["source", source, "title", title, "heading", heading, "content", content, "distance", distance.to_s]]
end

class ChunkerTest < Minitest::Test
  MD = <<~MD
    ---
    title: Wystawianie faktury korygującej
    audience: Księgowy
    last_verified: 2026-09-01
    questions:
      - Jak poprawić błędną fakturę?
      - Pomyliłem kwotę, co zrobić?
    ---

    # Wystawianie faktury korygującej

    Krótki opis.

    ## Kroki

    1. Kliknij **Koryguj**.
  MD

  def test_short_doc_single_chunk_questions_only_in_embed_text
    r = Rag::MarkdownChunker.call(MD, fallback_title: "x")
    assert_equal "Wystawianie faktury korygującej", r.title
    assert_equal 1, r.chunks.size
    c = r.chunks[0]
    assert_includes c.embed_text, "Pytania: Jak poprawić błędną fakturę? Pomyliłem kwotę, co zrobić?"
    assert c.embed_text.start_with?("Wystawianie faktury korygującej\n\n")
    refute_includes c.text, "Pytania:"
    refute_includes c.text, "Wystawianie faktury korygującej"
    assert c.text.start_with?("Krótki opis.")
  end

  def test_parse_returns_body_without_front_matter_and_h1
    p = Rag::MarkdownChunker.parse(MD, fallback_title: "x")
    assert_equal 2, p.questions.size
    refute_includes p.body, "questions:"
    refute_includes p.body, "# Wystawianie"
    assert_includes p.body, "## Kroki"
  end

  def test_long_doc_splits_by_h2_questions_in_first_chunk_only
    body = "a" * 900
    md = "---\nquestions: [Pytanie testowe]\n---\n# T\n\nWstęp #{body}\n\n## Sekcja A\n\n#{body}\n\n```\n## to nie nagłówek\n```\n\n## Sekcja B\n\n#{body}\n"
    r = Rag::MarkdownChunker.call(md, fallback_title: "x")
    assert_equal ["T", "T › Sekcja A", "T › Sekcja B"], r.chunks.map(&:heading)
    assert_includes r.chunks[1].text, "## to nie nagłówek"
    assert_includes r.chunks[0].embed_text, "Pytania: Pytanie testowe"
    refute_includes r.chunks[1].embed_text, "Pytania:"
  end

  def test_oversized_section_split_with_overlap
    paras = (1..12).map { |i| "Akapit #{i} " + ("x" * 200) }
    r = Rag::MarkdownChunker.call("# T\n\n## S\n\n" + paras.join("\n\n"), fallback_title: "x")
    assert r.chunks.size > 1
    r.chunks.each { |c| assert c.text.length <= Rag::MarkdownChunker::MAX_CHARS }
    assert_includes r.chunks[1].text, r.chunks[0].text.split("\n\n").last
    joined = r.chunks.map(&:text).join
    paras.each { |p| assert_includes joined, p }
  end

  def test_hard_split_no_redundant_tail
    r = Rag::MarkdownChunker.call("# T\n\n## S\n\n" + ("y" * 2700), fallback_title: "x")
    assert_equal 2, r.chunks.size
  end
end

class RetrieverTest < Minitest::Test
  def test_parse_resp2_and_pack_roundtrip
    raw = [2, *resp_row("k1", source: "docs/user/a.md", title: "A".b, heading: "A", content: "Zażółć".b, distance: 0.123),
           *resp_row("k2", source: "docs/user/b.md", title: "B", heading: "B › S", content: "x", distance: 0.4)]
    rows = Rag::Retriever.parse(raw)
    assert_equal 2, rows.size
    assert_equal "Zażółć", rows[0][:content]
    assert_equal Encoding::UTF_8, rows[0][:title].encoding
    assert_in_delta 0.123, rows[0][:distance]
    v = [0.5, -1.25, 3.0]
    assert_equal v, Rag::Index.pack(v).unpack("e*")
  end
end

module WithFakes
  def setup
    @redis = FakeRedis.new
    @ollama = FakeOllama.new
    Rag.instance_variable_set(:@redis, @redis)
    Rag.instance_variable_set(:@ollama, @ollama)
  end
end

class IndexerTest < Minitest::Test
  include WithFakes

  def setup
    super
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "docs/user/faktury"))
    @path = File.join(@dir, "docs/user/faktury/korekta.md")
    File.write(@path, ChunkerTest::MD)
    File.write(File.join(@dir, "docs/user/_szablon.md"), "# Szablon\n")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_source_paths_skip_underscore
    assert_equal ["docs/user/faktury/korekta.md"], Rag::Indexer.source_paths(@dir)
  end

  def test_stores_title_display_content_and_embeds_questions
    Rag::Indexer.call(root: @dir, logger: nil)
    key = @redis.hashes.keys.grep(/\Arag:chunk:/).first
    h = @redis.hashes[key]
    assert key.start_with?("rag:chunk:#{Rag::Index.id_for('docs/user/faktury/korekta.md')}:")
    assert_equal "Wystawianie faktury korygującej", h["title"]
    refute_includes h["content"], "Pytania:"
    assert_equal 1024 * 4, h["embedding"].bytesize
    assert_includes @ollama.embed_calls.first.first, "Pytania: Jak poprawić błędną fakturę?"
    create = @redis.calls.find { |c| c.first == "FT.CREATE" }
    assert_includes create, "title"
  end

  def test_incremental_update_and_delete
    Rag::Indexer.call(root: @dir, logger: nil)
    Rag::Indexer.call(root: @dir, logger: nil)
    assert_equal 1, @ollama.embed_calls.size

    File.write(@path, ChunkerTest::MD.sub("Krótki opis.", "Nowy opis."))
    Rag::Indexer.call(root: @dir, logger: nil)
    assert_equal 2, @ollama.embed_calls.size

    File.delete(@path)
    Rag::Indexer.call(root: @dir, logger: nil)
    assert_empty @redis.hashes.keys.grep(/\Arag:chunk:/)
    assert_empty @redis.hashes["rag:checksums"]
  end
end

class SearchTest < Minitest::Test
  include WithFakes

  def test_best_section_per_file_threshold_and_limit
    @redis.search_result = [5,
      *resp_row("a0", source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "kroki A", distance: 0.10),
      *resp_row("a1", source: "docs/user/a.md", title: "A", heading: "A › Wynik", content: "wynik A", distance: 0.15),
      *resp_row("b0", source: "docs/user/b.md", title: "B", heading: "B", content: "B", distance: 0.20),
      *resp_row("c0", source: "docs/user/c.md", title: "C", heading: "C", content: "C", distance: 0.30),
      *resp_row("d0", source: "docs/user/d.md", title: "D", heading: "D", content: "D", distance: 0.40)]
    r = Rag::Search.call("pytanie")
    assert r.found?
    assert_equal %w[docs/user/a.md docs/user/b.md docs/user/c.md], r.results.map { |x| x[:source] }
    assert_equal "kroki A", r.results[0][:content]
    assert_empty r.suggestions
    search = @redis.calls.find { |c| c.first == "FT.SEARCH" }
    assert_equal ["LIMIT", "0", Rag::Search::CANDIDATES.to_s], search[search.index("LIMIT"), 3]
  end

  def test_no_results_gives_title_suggestions
    @redis.search_result = [3,
      *resp_row("a0", source: "docs/user/a.md", title: "A", heading: "A", content: "A", distance: 0.70),
      *resp_row("a1", source: "docs/user/a.md", title: "A", heading: "A › S", content: "A2", distance: 0.72),
      *resp_row("b0", source: "docs/user/b.md", title: "B", heading: "B", content: "B", distance: 0.80)]
    r = Rag::Search.call("coś spoza zakresu")
    refute r.found?
    assert_equal [{ source: "docs/user/a.md", title: "A", distance: 0.70 },
                  { source: "docs/user/b.md", title: "B", distance: 0.80 }], r.suggestions
    refute r.suggestions.first.key?(:content)
  end

  def test_empty_question_does_not_call_ollama
    r = Rag::Search.call("   ")
    refute r.found?
    assert_empty @ollama.embed_calls
  end
end

class OllamaClientTest < Minitest::Test
  def test_embed_sends_truncate_false_and_raises_on_http_error
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    bodies = []
    thread = Thread.new do
      2.times do |i|
        s = server.accept
        headers = +""
        while (line = s.gets) && line != "\r\n"
          headers << line
        end
        bodies << JSON.parse(s.read(headers[/Content-Length: (\d+)/i, 1].to_i))
        payload = i.zero? ? JSON.generate({ "embeddings" => [[0.1, 0.2]] }) : '{"error":"model not found"}'
        status = i.zero? ? "200 OK" : "404 Not Found"
        s.write "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
        s.close
      end
    end
    client = Rag::OllamaClient.new(base_url: "http://127.0.0.1:#{port}")
    assert_equal [[0.1, 0.2]], client.embed(model: "bge-m3", input: ["a"])
    assert_equal false, bodies[0]["truncate"]
    refute bodies[0].key?("keep_alive"), "bez RAG_KEEP_ALIVE obowiązuje ustawienie serwera"
    err = assert_raises(Rag::OllamaClient::Error) { client.embed(model: "brak", input: ["a"]) }
    assert_match(/404/, err.message)
    thread.join
  ensure
    server&.close
  end
end

class DocsLintTest < Minitest::Test
  def test_lint
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config/locales"))
      FileUtils.mkdir_p(File.join(dir, "docs/user"))
      FileUtils.mkdir_p(File.join(dir, "test/system/docs"))
      File.write(File.join(dir, "config/locales/pl.yml"), <<~YML)
        pl:
          invoices:
            new: "Nowa faktura"
            created: "Utworzono fakturę nr %{number}"
      YML
      File.write(File.join(dir, "test/system/docs/ok_test.rb"), "")
      File.write(File.join(dir, "docs/user/ok.md"), <<~MD)
        ---
        title: OK
        audience: Księgowy
        verified_by: [test/system/docs/ok_test.rb]
        last_verified: 2026-09-01
        questions:
          - Jak dodać fakturę?
        ---
        # OK
        1. Kliknij **Nowa faktura**.
        Wynik: **Utworzono fakturę nr 12**.
        ```
        **Nie sprawdzaj w kodzie**
        ```
      MD
      File.write(File.join(dir, "docs/user/zle.md"), <<~MD)
        ---
        title: Złe
        verified_by: test/system/docs/brak_test.rb
        last_verified: wczoraj
        questions: "nie lista"
        ---
        # Złe
        Kliknij **Zapisz** jak wyżej.
      MD
      issues = DocsLint.call(root: dir)
      ok = issues.select { |i| i.location.start_with?("docs/user/ok.md") }
      assert_empty ok, ok.map(&:to_s).join("\n")
      msgs = issues.map(&:to_s).join("\n")
      assert_match(/brak pola front matter: audience/, msgs)
      assert_match(%r{nieistniejący plik: test/system/docs/brak_test.rb}, msgs)
      assert_match(/last_verified musi być datą/, msgs)
      assert_match(/questions musi być listą/, msgs)
      assert_match(/zle.md:8: etykieta \*\*Zapisz\*\*/, msgs)
      assert_match(%r{WARNING docs/user/zle.md:8: odwołanie "jak wyżej"}, msgs)
    end
  end
end


class FakeHttpServer
  attr_reader :requests, :port

  # responses: tablica [status, body_string]
  def initialize(responses)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @thread = Thread.new do
      responses.each do |status, payload|
        s = @server.accept
        request_line = s.gets
        headers = {}
        while (line = s.gets) && line != "\r\n"
          k, v = line.split(":", 2)
          headers[k.strip.downcase] = v.strip
        end
        body = s.read(headers["content-length"].to_i)
        @requests << { line: request_line, headers: headers, body: JSON.parse(body) }
        s.write "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
        s.close
      end
    end
  end

  def url = "http://127.0.0.1:#{@port}/v1beta"
  def join = @thread.join(5)
  def close = @server.close
end

class GeminiClientTest < Minitest::Test
  OK_BODY = JSON.generate({
    "candidates" => [{ "content" => { "role" => "model", "parts" => [
      { "text" => "myślenie", "thought" => true }, { "text" => "Kliknij " }, { "text" => "Koryguj [1]." }
    ] }, "finishReason" => "STOP" }],
    "usageMetadata" => { "promptTokenCount" => 1200, "candidatesTokenCount" => 20 }
  })

  def test_request_format_and_parsing
    server = FakeHttpServer.new([["200 OK", OK_BODY]])
    client = Rag::GeminiClient.new(api_key: "SEKRET", base_url: server.url)
    r = client.generate(model: "gemini-3.1-flash-lite", system_instruction: "SYS", user_text: "PYT",
                        max_output_tokens: 512, thinking_level: "low")
    server.join
    req = server.requests.first
    assert_match %r{\APOST /v1beta/models/gemini-3.1-flash-lite:generateContent HTTP}, req[:line]
    refute_includes req[:line], "SEKRET"
    assert_equal "SEKRET", req[:headers]["x-goog-api-key"]
    assert_equal "SYS", req[:body].dig("systemInstruction", "parts", 0, "text")
    assert_equal "PYT", req[:body].dig("contents", 0, "parts", 0, "text")
    assert_equal "user", req[:body].dig("contents", 0, "role")
    assert_equal 512, req[:body].dig("generationConfig", "maxOutputTokens")
    assert_equal "low", req[:body].dig("generationConfig", "thinkingConfig", "thinkingLevel")
    refute req[:body]["generationConfig"].key?("temperature")
    assert_equal "Kliknij Koryguj [1].", r.text
    assert_equal "STOP", r.finish_reason
    assert_equal 1200, r.usage["promptTokenCount"]
  ensure
    server&.close
  end

  def test_no_thinking_config_when_level_nil
    server = FakeHttpServer.new([["200 OK", OK_BODY]])
    Rag::GeminiClient.new(api_key: "k", base_url: server.url)
                     .generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    server.join
    refute server.requests.first[:body]["generationConfig"].key?("thinkingConfig")
  ensure
    server&.close
  end

  def test_429_retried_then_raises_rate_limited
    err = '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}'
    server = FakeHttpServer.new([["429 Too Many Requests", err]] * 3)
    sleeps = []
    client = Rag::GeminiClient.new(api_key: "k", base_url: server.url, max_retries: 2, sleeper: ->(s) { sleeps << s })
    assert_raises(Rag::GeminiClient::RateLimited) do
      client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    end
    server.join
    assert_equal 3, server.requests.size
    assert_equal [1, 2], sleeps
  ensure
    server&.close
  end

  def test_503_then_success
    server = FakeHttpServer.new([["503 Service Unavailable", "{}"], ["200 OK", OK_BODY]])
    client = Rag::GeminiClient.new(api_key: "k", base_url: server.url, sleeper: ->(_) {})
    r = client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    server.join
    assert_equal "Kliknij Koryguj [1].", r.text
  ensure
    server&.close
  end

  def test_400_not_retried
    server = FakeHttpServer.new([["400 Bad Request", '{"error":{"status":"FAILED_PRECONDITION"}}']])
    client = Rag::GeminiClient.new(api_key: "k", base_url: server.url, sleeper: ->(_) { flunk "nie ponawiać 400" })
    e = assert_raises(Rag::GeminiClient::Error) do
      client.generate(model: "m", system_instruction: "s", user_text: "u", max_output_tokens: 10)
    end
    refute_kind_of Rag::GeminiClient::RetryableError, e
    assert_match(/FAILED_PRECONDITION/, e.message)
    server.join
  ensure
    server&.close
  end

  def test_rejects_bad_model_name_and_missing_key
    assert_raises(ArgumentError) { Rag::GeminiClient.new(api_key: "") }
    c = Rag::GeminiClient.new(api_key: "k", base_url: "http://127.0.0.1:1")
    assert_raises(ArgumentError) { c.generate(model: "../x", system_instruction: "s", user_text: "u", max_output_tokens: 1) }
  end
end

class FakeGemini
  attr_reader :calls
  def initialize(response: nil, error: nil)
    @response = response
    @error = error
    @calls = []
  end

  def generate(**kw)
    @calls << kw
    raise @error if @error

    @response
  end
end

class AnswerTest < Minitest::Test
  SOURCES = [
    { source: "docs/user/a.md", title: "A", heading: "A › Kroki", content: "1. Kliknij **Koryguj**.", distance: 0.1 },
    { source: "docs/user/b.md", title: "B", heading: "B", content: "Treść B", distance: 0.2 }
  ].freeze

  def found = Rag::Search::Result.new(results: SOURCES.map(&:dup), suggestions: [])
  def empty = Rag::Search::Result.new(results: [], suggestions: [{ source: "x", title: "X", distance: 0.9 }])
  def ok_response(text) = Rag::GeminiClient::Response.new(text: text, finish_reason: "STOP", usage: {})

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_enabled_requires_key_and_development
    with_env("RAG_GEMINI_API_KEY" => nil, "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => nil) do
      refute Rag::Answer.enabled?(env: "development")
    end
    with_env("RAG_GEMINI_API_KEY" => "k", "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => nil) do
      assert Rag::Answer.enabled?(env: "development")
      refute Rag::Answer.enabled?(env: "production")
    end
    with_env("RAG_GEMINI_API_KEY" => "k", "RAG_GEMINI_ALLOW_OUTSIDE_DEVELOPMENT" => "1") do
      assert Rag::Answer.enabled?(env: "production")
    end
  end

  def test_disabled_and_no_results_do_not_call_api
    gem = FakeGemini.new(response: ok_response("x"))
    with_env("RAG_GEMINI_API_KEY" => nil) do
      r = Rag::Answer.call("p", env: "development", search_result: found, client: gem)
      assert_equal :disabled, r.status
    end
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = Rag::Answer.call("p", env: "development", search_result: empty, client: gem)
      assert_equal :no_results, r.status
    end
    assert_empty gem.calls
  end

  def test_ok_prompt_contains_numbered_sources
    gem = FakeGemini.new(response: ok_response("Kliknij Koryguj [1]."))
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = Rag::Answer.call("Jak poprawić fakturę?", env: "development", search_result: found, client: gem)
      assert_equal :ok, r.status
      assert_equal 2, r.sources.size
    end
    call = gem.calls.first
    assert_equal Rag::Answer::MODEL, call[:model]
    assert_includes call[:user_text], "[1] A › Kroki (docs/user/a.md)\n1. Kliknij **Koryguj**."
    assert_includes call[:user_text], "[2] B (docs/user/b.md)"
    assert call[:user_text].end_with?("Pytanie: Jak poprawić fakturę?")
    assert_includes call[:system_instruction], Rag::Answer::NO_ANSWER
  end

  def test_not_in_docs_empty_rate_limited_error
    with_env("RAG_GEMINI_API_KEY" => "k") do
      r = Rag::Answer.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(response: ok_response(Rag::Answer::NO_ANSWER)))
      assert_equal :not_in_docs, r.status

      r = Rag::Answer.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(response: Rag::GeminiClient::Response.new(text: "", finish_reason: "SAFETY", usage: {})))
      assert_equal :error, r.status

      r = Rag::Answer.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(error: Rag::GeminiClient::RateLimited.new("429")))
      assert_equal :rate_limited, r.status
      assert_equal 2, r.sources.size

      r = Rag::Answer.call("p", env: "development", search_result: found,
                                client: FakeGemini.new(error: Rag::GeminiClient::Error.new("400")))
      assert_equal :error, r.status
    end
  end

  def test_citation_issues
    assert_empty Rag::Answer.citation_issues("Tak [1]. Potem [2].", 2)
    assert_equal ["brak odwołań [n]"], Rag::Answer.citation_issues("Tak.", 2)
    assert_equal ["odwołania poza zakresem: 3"], Rag::Answer.citation_issues("Tak [3].", 2)
    assert_empty Rag::Answer.citation_issues(Rag::Answer::NO_ANSWER, 2)
  end
end
