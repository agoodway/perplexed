defmodule Perplexed.ModelTest do
  use ExUnit.Case, async: true

  alias Perplexed.Model

  describe "fetch/1" do
    test "accepts a string, tuple or map model spec" do
      assert Model.fetch(model: "openai:gpt-test") == {:ok, "openai:gpt-test"}
      assert Model.fetch(model: {:openai, "gpt-test", []}) == {:ok, {:openai, "gpt-test", []}}

      assert Model.fetch(model: %{provider: :openai, id: "gpt-test"}) ==
               {:ok, %{provider: :openai, id: "gpt-test"}}
    end

    test "rejects a missing model" do
      assert Model.fetch(model: nil) == {:error, {:invalid_request, %{reason: :no_model}}}
      assert Model.fetch(model: "") == {:error, {:invalid_request, %{reason: :no_model}}}
    end
  end
end
