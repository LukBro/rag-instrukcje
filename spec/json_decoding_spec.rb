require "rails_helper"

# json 3.x makes JSON.parse keyword-only, which breaks ActiveSupport 8.1 (BRO-44).
RSpec.describe "JSON decoding" do
  it "decodes a JSON object with ActiveSupport" do
    expect(ActiveSupport::JSON.decode('{"question":"Jak?"}')).to eq("question" => "Jak?")
  end

  it "parses a JSON request body into params" do
    request = ActionDispatch::Request.new(
      Rack::MockRequest.env_for("/", method: "POST", input: '{"question":"Jak?"}',
                                     "CONTENT_TYPE" => "application/json")
    )

    expect(request.request_parameters).to eq("question" => "Jak?")
  end
end
