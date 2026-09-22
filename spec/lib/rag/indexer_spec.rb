require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rag::Indexer do
  include_context "rag fakes"

  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "docs/user/faktury/korekta.md") }

  before do
    FileUtils.mkdir_p(File.join(dir, "docs/user/faktury"))
    File.write(path, RAG_SAMPLE_MD)
    File.write(File.join(dir, "docs/user/_szablon.md"), "# Szablon\n")
  end

  after { FileUtils.rm_rf(dir) }

  it "pomija pliki zaczynające się od podkreślnika" do
    expect(described_class.source_paths(dir)).to eq(["docs/user/faktury/korekta.md"])
  end

  it "zapisuje tytuł, treść i embeduje pytania" do
    described_class.call(root: dir, logger: nil)
    key = fake_redis.hashes.keys.grep(/\Arag:chunk:/).first
    h = fake_redis.hashes[key]
    expect(key).to start_with("rag:chunk:#{Rag::Index.id_for('docs/user/faktury/korekta.md')}:")
    expect(h["title"]).to eq("Wystawianie faktury korygującej")
    expect(h["content"]).not_to include("Pytania:")
    expect(h["embedding"].bytesize).to eq(1024 * 4)
    expect(fake_ollama.embed_calls.first.first).to include("Pytania: Jak poprawić błędną fakturę?")
    create = fake_redis.calls.find { |c| c.first == "FT.CREATE" }
    expect(create).to include("title")
  end

  it "aktualizuje przyrostowo i usuwa po skasowaniu pliku" do
    described_class.call(root: dir, logger: nil)
    described_class.call(root: dir, logger: nil)
    expect(fake_ollama.embed_calls.size).to eq(1)

    File.write(path, RAG_SAMPLE_MD.sub("Krótki opis.", "Nowy opis."))
    described_class.call(root: dir, logger: nil)
    expect(fake_ollama.embed_calls.size).to eq(2)

    File.delete(path)
    described_class.call(root: dir, logger: nil)
    expect(fake_redis.hashes.keys.grep(/\Arag:chunk:/)).to be_empty
    expect(fake_redis.hashes["rag:checksums"]).to be_empty
  end
end
