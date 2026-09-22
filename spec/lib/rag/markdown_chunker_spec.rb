require "rails_helper"

RSpec.describe Rag::MarkdownChunker do
  MD = RAG_SAMPLE_MD

  it "dla krótkiego dokumentu tworzy jeden fragment, pytania tylko w embed_text" do
    r = described_class.call(MD, fallback_title: "x")
    expect(r.title).to eq("Wystawianie faktury korygującej")
    expect(r.chunks.size).to eq(1)
    c = r.chunks[0]
    expect(c.embed_text).to include("Pytania: Jak poprawić błędną fakturę? Pomyliłem kwotę, co zrobić?")
    expect(c.embed_text).to start_with("Wystawianie faktury korygującej\n\n")
    expect(c.text).not_to include("Pytania:")
    expect(c.text).not_to include("Wystawianie faktury korygującej")
    expect(c.text).to start_with("Krótki opis.")
  end

  it "parse zwraca treść bez front matter i H1" do
    p = described_class.parse(MD, fallback_title: "x")
    expect(p.questions.size).to eq(2)
    expect(p.body).not_to include("questions:")
    expect(p.body).not_to include("# Wystawianie")
    expect(p.body).to include("## Kroki")
  end

  it "dla długiego dokumentu dzieli po H2, pytania tylko w pierwszym fragmencie" do
    body = "a" * 900
    md = "---\nquestions: [Pytanie testowe]\n---\n# T\n\nWstęp #{body}\n\n## Sekcja A\n\n#{body}\n\n```\n## to nie nagłówek\n```\n\n## Sekcja B\n\n#{body}\n"
    r = described_class.call(md, fallback_title: "x")
    expect(r.chunks.map(&:heading)).to eq(["T", "T › Sekcja A", "T › Sekcja B"])
    expect(r.chunks[1].text).to include("## to nie nagłówek")
    expect(r.chunks[0].embed_text).to include("Pytania: Pytanie testowe")
    expect(r.chunks[1].embed_text).not_to include("Pytania:")
  end

  it "dzieli zbyt dużą sekcję z zakładką (overlap)" do
    paras = (1..12).map { |i| "Akapit #{i} " + ("x" * 200) }
    r = described_class.call("# T\n\n## S\n\n" + paras.join("\n\n"), fallback_title: "x")
    expect(r.chunks.size).to be > 1
    r.chunks.each { |c| expect(c.text.length).to be <= Rag::MarkdownChunker::MAX_CHARS }
    expect(r.chunks[1].text).to include(r.chunks[0].text.split("\n\n").last)
    joined = r.chunks.map(&:text).join
    paras.each { |p| expect(joined).to include(p) }
  end

  it "dla twardego podziału nie zostawia zbędnej zakładki" do
    r = described_class.call("# T\n\n## S\n\n" + ("y" * 2700), fallback_title: "x")
    expect(r.chunks.size).to eq(2)
  end
end
