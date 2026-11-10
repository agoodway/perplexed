defmodule Perplexed.Search.FallbackTest do
  use ExUnit.Case, async: true

  alias Perplexed.Fixtures.SearchProvider
  alias Perplexed.Search
  alias Perplexed.Search.{Hit, Result}

  # SearchProvider answers with `reply.(query)` and lists at $0.004.
  defp provider(reply), do: {SearchProvider, reply: reply}

  defp hits(url), do: fn _query -> {:ok, [%Hit{url: url, provider: :stub}]} end
  defp empty, do: fn _query -> {:ok, []} end
  defp failing, do: fn _query -> {:error, {:rate_limited, %{}}} end
  defp slow(ms), do: fn _query -> Process.sleep(ms) && {:ok, []} end

  test "falls back past a failing provider and says what each did" do
    chain = [provider(failing()), provider(hits("https://second.example/"))]

    assert {:ok,
            %Result{hits: [%Hit{url: "https://second.example/"}], attempts: attempts} = result} =
             Search.run(chain, "q")

    assert [%{outcome: {:error, {:rate_limited, %{}}}, cost: +0.0}, %{outcome: :ok, cost: 0.004}] =
             attempts

    assert result.provider == SearchProvider

    assert result.cost == 0.004
  end

  test "an empty answer falls back too, and still counts what it cost" do
    chain = [provider(empty()), provider(hits("https://second.example/"))]

    assert {:ok, %Result{hits: [_], cost: cost, attempts: [%{outcome: :empty}, %{outcome: :ok}]}} =
             Search.run(chain, "q")

    assert_in_delta cost, 0.008, 1.0e-9
  end

  test "fallback_on: [:error] keeps an empty answer instead of moving on" do
    chain = [provider(empty()), provider(hits("https://never.example/"))]

    assert {:ok, %Result{hits: [], attempts: [%{outcome: :empty}]}} =
             Search.run(chain, "q", fallback_on: [:error])
  end

  test "fallback_on: [:empty] stops at an error" do
    chain = [provider(failing()), provider(hits("https://never.example/"))]

    assert {:error, {:rate_limited, %{attempts: [%{outcome: {:error, _}}]}}} =
             Search.run(chain, "q", fallback_on: [:empty])
  end

  test "a provider that overruns its time is shut down and the next one runs" do
    chain = [provider(slow(5_000)), provider(hits("https://fast.example/"))]

    assert {:ok,
            %Result{hits: [_], attempts: [%{outcome: :timeout, duration_ms: ms}, %{outcome: :ok}]}} =
             Search.run(chain, "q", provider_timeout_ms: 50)

    assert ms < 1_000
  end

  test "providers left when the deadline passes are not called" do
    test_pid = self()
    never = fn _query -> send(test_pid, :called) && {:ok, []} end
    chain = [provider(slow(5_000)), provider(never)]

    assert {:error, {:upstream, %{reason: :all_providers_failed, attempts: attempts}}} =
             Search.run(chain, "q", provider_timeout_ms: 1_000, deadline_ms: 60)

    assert [%{outcome: :timeout}, %{outcome: :deadline}] = attempts
    refute_received :called
  end

  test "when every provider fails, an empty answer is still the result" do
    chain = [provider(failing()), provider(empty()), provider(failing())]

    assert {:ok, %Result{hits: [], attempts: [_, %{outcome: :empty}, _]}} = Search.run(chain, "q")
  end

  test "with no answer at all it lists every attempt" do
    chain = [provider(failing()), provider(failing())]

    assert {:error, {:upstream, %{reason: :all_providers_failed, attempts: [_, _]}}} =
             Search.run(chain, "q")
  end

  test "an unknown provider in the chain is skipped like any failure" do
    assert {:ok,
            %Result{attempts: [%{outcome: {:error, {:invalid_request, _}}}, %{outcome: :ok}]}} =
             Search.run([:nope, provider(hits("https://x.example/"))], "q")
  end

  test "Perplexed.search/2 takes a chain as :provider" do
    assert {:ok, %Result{hits: [_], attempts: [_, _]}} =
             Perplexed.search("q",
               provider: [provider(failing()), provider(hits("https://x.example/"))]
             )
  end

  @tag capture_log: true
  test "a provider that crashes is an attempt, and the crash keeps no arguments" do
    crashing = fn _query -> raise "boom" end

    assert {:ok,
            %Result{
              attempts: [%{outcome: {:error, {:exit, %{reason: RuntimeError}}}}, %{outcome: :ok}]
            }} =
             Search.run([provider(crashing), provider(hits("https://x.example/"))], "q")
  end

  test "with no time left no provider is called" do
    test_pid = self()
    never = fn _query -> send(test_pid, :called) && {:ok, []} end

    assert {:error,
            {:upstream,
             %{
               reason: :all_providers_failed,
               attempts: [%{outcome: :deadline}, %{outcome: :deadline}]
             }}} =
             Search.run([provider(never), provider(never)], "q", deadline_ms: 0)

    refute_received :called
  end

  test "reports providers by name, never their options" do
    secret =
      {SearchProvider, reply: hits("https://x.example/"), credentials: [api_key: "sk-secret"]}

    assert {:ok,
            %Result{provider: SearchProvider, attempts: [%{provider: SearchProvider}]} = result} =
             Search.run([secret], "q")

    refute inspect(result) =~ "sk-secret"
  end

  test "a single provider has no attempts list" do
    assert {:ok, %Result{attempts: []}} = Search.run(provider(hits("https://x.example/")), "q")
  end
end
