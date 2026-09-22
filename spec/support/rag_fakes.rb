# frozen_string_literal: true

require "socket"

# Atrapy Redis i Ollama używane w spec/lib/rag/*_spec.rb (bez sieci, bez prawdziwego Redis/Ollama).
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

RAG_SAMPLE_MD = <<~MD
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

def resp_row(key, source:, title:, heading:, content:, distance:)
  [key, ["source", source, "title", title, "heading", heading, "content", content, "distance", distance.to_s]]
end

RSpec.shared_context "rag fakes" do
  let(:fake_redis) { FakeRedis.new }
  let(:fake_ollama) { FakeOllama.new }

  before do
    Rag.instance_variable_set(:@redis, fake_redis)
    Rag.instance_variable_set(:@ollama, fake_ollama)
  end
end

# Minimalny serwer HTTP na potrzeby testów klientów Ollama i Gemini (bez sieci zewnętrznej).
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
