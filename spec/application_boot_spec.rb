require "rails_helper"

RSpec.describe Rails.application do
  it "eager loads the application code" do
    expect { described_class.eager_load! }.not_to raise_error
  end
end
