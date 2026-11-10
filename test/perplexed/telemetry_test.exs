defmodule Perplexed.TelemetryTest do
  # Attaches global telemetry handlers.
  use ExUnit.Case, async: false

  alias Perplexed.{Document, Fixtures, Model, Scrape, Search}
  alias Perplexed.Fixtures.{PaidScraper, SearchProvider}
  alias Perplexed.Search.Hit
  alias ReqLLM.Context

  import Perplexed.Fixtures, only: [capture_telemetry: 1]

  @events [
    [:perplexed, :search, :start],
    [:perplexed, :search, :stop],
    [:perplexed, :scrape, :start],
    [:perplexed, :scrape, :stop],
    [:perplexed, :model]
  ]

  def handle(event, measurements, metadata, %{pid: pid}),
    do: send(pid, {:telemetry, event, measurements, metadata})

  setup context do
    id = "telemetry-test-#{inspect(context.test)}"
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle/4, %{pid: self()})
    on_exit(fn -> :telemetry.detach(id) end)

    restore = Fixtures.put_config(url_validator: {Fixtures, :allow_url, []})
    on_exit(restore)

    {:ok, unique: System.unique_integer([:positive])}
  end

  describe "[:perplexed, :search] span" do
    test "a successful search reports duration, cost, hits and result", %{unique: unique} do
      query = "search ok #{unique}"
      hits = [%Hit{url: "https://example.org/a"}, %Hit{url: "https://example.org/b"}]
      provider = {SearchProvider, reply: fn _query -> {:ok, hits} end}

      assert {:ok, _result} = Search.run(provider, query)

      assert_received {:telemetry, [:perplexed, :search, :start], %{system_time: _},
                       %{query: ^query, provider: SearchProvider}}

      assert_received {:telemetry, [:perplexed, :search, :stop], measurements,
                       %{query: ^query, provider: SearchProvider, result: :ok}}

      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert measurements.hits == 2
      assert_in_delta measurements.cost, 0.004, 1.0e-9
    end

    test "a failed search reports zero cost and hits with result error", %{unique: unique} do
      query = "search error #{unique}"
      provider = {SearchProvider, reply: fn _query -> {:error, {:upstream, %{}}} end}

      assert {:error, {:upstream, %{}}} = Search.run(provider, query)

      assert_received {:telemetry, [:perplexed, :search, :stop], measurements,
                       %{query: ^query, provider: SearchProvider, result: :error}}

      assert measurements.cost == 0.0
      assert measurements.hits == 0
      assert is_integer(measurements.duration)
    end

    test "an empty result costs the provider's price", %{unique: unique} do
      query = "search empty #{unique}"
      provider = {SearchProvider, reply: fn _query -> {:ok, []} end}

      assert {:ok, _result} = Search.run(provider, query)

      assert_received {:telemetry, [:perplexed, :search, :stop], %{hits: 0, cost: 0.004},
                       %{query: ^query, result: :ok}}
    end
  end

  describe "[:perplexed, :scrape] span" do
    defp readable(url),
      do: {:ok, %Document{markdown: Fixtures.readable_text(), final_url: url}, nil}

    test "a readable page reports tier, attempts, cost and result", %{unique: unique} do
      url = "https://example.org/ok-#{unique}"
      ladder = [{PaidScraper, reply: &readable/1}]

      assert {:ok, %Document{}} = Scrape.run(url, ladder: ladder)

      assert_received {:telemetry, [:perplexed, :scrape, :start], %{system_time: _}, %{url: ^url}}

      assert_received {:telemetry, [:perplexed, :scrape, :stop], measurements,
                       %{url: ^url, tier: PaidScraper, attempts: attempts, result: :ok}}

      assert attempts == [{PaidScraper, :ok}]
      assert is_integer(measurements.duration)
      assert_in_delta measurements.cost, 0.01, 1.0e-9
      assert measurements.browser_ms == 0
    end

    test "an unreadable page reports the failed attempts with no tier", %{unique: unique} do
      url = "https://example.org/missing-#{unique}"
      ladder = [{PaidScraper, reply: fn _url -> {:error, :not_found} end}]

      assert {:error, {:unreadable, _details}} = Scrape.run(url, ladder: ladder)

      assert_received {:telemetry, [:perplexed, :scrape, :stop], measurements,
                       %{url: ^url, tier: nil, attempts: attempts, result: :error}}

      assert attempts == [{PaidScraper, :not_found}]
      assert measurements.cost == 0.0
      assert measurements.browser_ms == 0
    end

    test "a paid page judged unreadable still reports its cost", %{unique: unique} do
      url = "https://example.org/short-#{unique}"
      short = fn _url -> {:ok, %Document{markdown: "Too short."}, nil} end

      assert {:error, {:unreadable, _details}} =
               Scrape.run(url, ladder: [{PaidScraper, reply: short}])

      assert_received {:telemetry, [:perplexed, :scrape, :stop], measurements,
                       %{url: ^url, result: :error}}

      assert_in_delta measurements.cost, 0.01, 1.0e-9
    end
  end

  describe "[:perplexed, :model] event" do
    test "Model.entry/4 emits token counts, cost, model and phase", %{unique: unique} do
      model = "test:model-#{unique}"
      usage = %{input_tokens: 120, output_tokens: 15, total_tokens: 135, total_cost: 0.0015}
      response = Fixtures.text_response(Context.new(), "hello", usage)

      entry = Model.entry(response, model, :summarize, %{note: :extra})

      assert_received {:telemetry, [:perplexed, :model], measurements,
                       %{model: ^model, phase: :summarize}}

      assert measurements.input_tokens == 120
      assert measurements.output_tokens == 15
      assert measurements.total_tokens == 135
      assert_in_delta measurements.cost, 0.0015, 1.0e-9

      assert %{kind: :model, phase: :summarize, input_tokens: 120, note: :extra} = entry
      assert_in_delta entry.cost, 0.0015, 1.0e-9
    end

    test "an unpriced call emits a nil cost", %{unique: unique} do
      model = "test:model-#{unique}"
      response = Fixtures.text_response(Context.new(), "hello", %{input_tokens: 5})

      assert %{cost: nil} = Model.entry(response, model, :plan)

      assert_received {:telemetry, [:perplexed, :model], %{input_tokens: 5, cost: nil},
                       %{model: ^model, phase: :plan}}
    end
  end

  describe "attempt events" do
    test "a search chain reports every attempt with whether it was billed" do
      capture_telemetry([[:perplexed, :search, :attempt]])
      failing = {SearchProvider, reply: fn _query -> {:error, {:upstream, %{}}} end}

      answering =
        {SearchProvider, reply: fn _query -> {:ok, [%Hit{url: "https://x.example/"}]} end}

      Search.run([failing, answering], "q")

      assert_received {:telemetry, _, %{cost: +0.0},
                       %{provider: SearchProvider, outcome: {:error, _}, billable: false}}

      assert_received {:telemetry, _, %{cost: 0.004},
                       %{provider: SearchProvider, outcome: :ok, billable: true}}
    end
  end
end
