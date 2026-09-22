require "rails_helper"

RSpec.describe Rag::Retriever do
  it "parsuje RESP2 i pakuje/rozpakowuje wektor" do
    raw = [2, *resp_row("k1", source: "docs/user/a.md", title: "A".b, heading: "A", content: "Zażółć".b, distance: 0.123),
           *resp_row("k2", source: "docs/user/b.md", title: "B", heading: "B › S", content: "x", distance: 0.4)]
    rows = described_class.parse(raw)
    expect(rows.size).to eq(2)
    expect(rows[0][:content]).to eq("Zażółć")
    expect(rows[0][:title].encoding).to eq(Encoding::UTF_8)
    expect(rows[0][:distance]).to be_within(0.0001).of(0.123)
    v = [0.5, -1.25, 3.0]
    expect(Rag::Index.pack(v).unpack("e*")).to eq(v)
  end
end
