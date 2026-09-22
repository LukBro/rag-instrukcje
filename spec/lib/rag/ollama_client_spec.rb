require "rails_helper"

RSpec.describe Rag::OllamaClient do
  it "wysyła truncate: false i zgłasza błąd przy odpowiedzi HTTP != 2xx" do
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
    client = described_class.new(base_url: "http://127.0.0.1:#{port}")
    expect(client.embed(model: "bge-m3", input: ["a"])).to eq([[0.1, 0.2]])
    expect(bodies[0]["truncate"]).to eq(false)
    expect(bodies[0]).not_to have_key("keep_alive")
    expect { client.embed(model: "brak", input: ["a"]) }
      .to raise_error(Rag::OllamaClient::Error, /404/)
    thread.join
  ensure
    server&.close
  end
end
