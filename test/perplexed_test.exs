defmodule PerplexedTest do
  # Starts and stops its own Perplexed instance, which touches the shared settings.
  use ExUnit.Case, async: false

  alias Perplexed.{Config, Fixtures}
  alias Perplexed.Fixtures.SearchProvider
  alias Perplexed.Search.{Hit, Result}

  describe "child_spec/1" do
    test "starts Perplexed with its settings and clears them when stopped" do
      previous = Config.all()

      on_exit(fn ->
        Supervisor.restart_child(Perplexed.TestSupervisor, Perplexed)
        Config.put(previous)
      end)

      :ok = Supervisor.terminate_child(Perplexed.TestSupervisor, Perplexed)
      assert Config.all() == []

      {:ok, pid} =
        Supervisor.start_link([{Perplexed, [firecrawl_api_key: "fc-test"]}],
          strategy: :one_for_one
        )

      assert Config.get(:firecrawl_api_key) == "fc-test"
      assert Process.whereis(Perplexed.TaskSupervisor)

      Supervisor.stop(pid)
      assert Config.all() == []
    end
  end

  describe "settings safety" do
    test "the settings owner keeps no copy of the settings in its state" do
      assert :sys.get_state(Perplexed.Settings) == nil
    end

    test "a child spec does not expose its settings when inspected" do
      refute inspect(Perplexed.child_spec(firecrawl_api_key: "fc-secret")) =~ "fc-secret"
    end

    test "the task supervisor belongs to the library, not to the settings" do
      on_exit(fn -> Supervisor.restart_child(Perplexed.TestSupervisor, Perplexed) end)
      :ok = Supervisor.terminate_child(Perplexed.TestSupervisor, Perplexed)
      assert Process.whereis(Perplexed.TaskSupervisor)
    end
  end

  describe "search/2" do
    test "returns a result with hits and cost from the chosen provider" do
      reply = fn query -> {:ok, [%Hit{url: "https://#{query}.test/"}]} end

      assert {:ok, %Result{hits: [%Hit{url: "https://museum.test/"}], cost: 0.004}} =
               Perplexed.search("museum", provider: {SearchProvider, reply: reply})
    end
  end

  describe "answer/2" do
    test "rejects an empty question" do
      assert Perplexed.answer("") == {:error, {:invalid_request, %{reason: :empty_query}}}
    end
  end

  describe "settings" do
    test "a configured price overrides a provider's list price" do
      on_exit(Fixtures.put_config(prices: %{ceramic: 0.001}))
      assert Perplexed.Search.price(:ceramic) == 0.001
      assert Perplexed.Search.price(:linkup) == 0.005
    end
  end
end
