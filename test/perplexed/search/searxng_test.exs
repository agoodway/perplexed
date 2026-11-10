defmodule Perplexed.Search.SearXNGTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Fixtures, Search}
  alias Perplexed.Search.{Hit, Result, SearXNG}
  alias Perplexed.Search.SearXNG.{Parser, Pool}

  @fixtures Path.expand("../../fixtures/searxng", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  setup do
    name = :"pool_#{System.unique_integer([:positive])}"
    start_supervised!({Pool, name: name})
    %{pool: name}
  end

  # Deterministic ranking: no jitter, no rest interval.
  defp search(query, opts),
    do:
      SearXNG.search(
        query,
        Keyword.merge(
          [jitter: 0, min_interval_ms: 0, url_validator: {Fixtures, :allow_url, []}],
          opts
        )
      )

  defp measure(instance, outcome, ms, pool) do
    [lease] = Pool.checkout([instance], 1, pool: pool)
    Pool.record(lease, outcome, ms, pool: pool)
  end

  # A plug that answers per instance host: `routes` maps host to
  # `{status, body}`, and every request is reported to the test process.
  defp router(test_pid, routes) do
    fn conn ->
      send(test_pid, {:searched, conn.host, Plug.Conn.fetch_query_params(conn).query_params})
      {status, body} = Map.fetch!(routes, conn.host)
      Plug.Conn.send_resp(conn, status, body)
    end
  end

  describe "Parser" do
    test "reads titles, URLs, snippets and engines from a results page" do
      assert {:ok, [first | _] = hits} =
               Parser.parse(200, fixture("results_bing_brave.html"), :html)

      assert length(hits) == 30
      assert first.url == "https://elixir-lang.org/"
      assert first.title == "The Elixir programming language"
      assert first.description =~ "dynamic, functional language"
      assert first.engines == ["bing"]
      assert Enum.any?(hits, &(&1.url =~ "reddit.com/r/elixir"))
    end

    test "keeps every engine a result came from" do
      {:ok, hits} = Parser.parse(200, fixture("results_mixed.html"), :html)

      assert hits |> Enum.flat_map(& &1.engines) |> Enum.uniq() |> Enum.sort() ==
               ["bing", "duckduckgo", "google cse", "mwmbl"]
    end

    test "calls bot checks in front of an instance challenges, not results" do
      for page <- ~w(challenge_anubis.html challenge_portico.html challenge_browser_check.html) do
        assert Parser.parse(200, fixture(page), :html) == {:error, :challenge}, page
      end
    end

    test "maps refusals by status" do
      assert Parser.parse(429, "", :html) == {:error, :rate_limited}
      assert Parser.parse(403, "", :html) == {:error, :blocked}
      assert Parser.parse(418, "", :html) == {:error, :blocked}
      assert Parser.parse(302, "", :html) == {:error, :blocked}
      assert Parser.parse(503, "", :html) == {:error, :unavailable}
      assert Parser.parse(500, "", :html) == {:error, :http_error}
    end

    test "keeps only well-formed JSON results" do
      body =
        Jason.encode!(%{
          "results" => [
            "not an object",
            1,
            %{
              "url" => "https://a.example/",
              "title" => %{"x" => 1},
              "content" => 5,
              "engines" => "bing"
            },
            %{"title" => "no url"}
          ]
        })

      assert {:ok, [%Hit{url: "https://a.example/", title: nil, description: nil, engines: []}]} =
               Parser.parse(200, body, :json)
    end

    test "keeps only plain engine names, at most eight" do
      names = ["bing", "<b>evil</b>", String.duplicate("x", 40)] ++ Enum.map(1..10, &"e#{&1}")
      body = Jason.encode!(%{"results" => [%{"url" => "https://a.example/", "engines" => names}]})

      assert {:ok, [%Hit{engines: engines}]} = Parser.parse(200, body, :json)
      assert engines == ["bing" | Enum.map(1..7, &"e#{&1}")]
    end

    test "reads the JSON API" do
      body =
        Jason.encode!(%{
          "results" => [
            %{
              "url" => "https://hexdocs.pm/elixir/GenServer.html",
              "title" => "GenServer",
              "content" => "A behaviour module",
              "engines" => ["duckduckgo", "brave"]
            }
          ]
        })

      assert {:ok, [%Hit{engines: ["duckduckgo", "brave"], description: "A behaviour module"}]} =
               Parser.parse(200, body, :json)

      assert Parser.parse(200, ~s({"results": []}), :json) == {:error, :no_results}
    end
  end

  describe "search/2 waterfall" do
    test "goes down the ranking past refusing instances and learns from them", %{pool: pool} do
      measure("https://fast.test/", {:ok, 10}, 100, pool)
      measure("https://second.test/", {:ok, 10}, 300, pool)
      measure("https://third.test/", {:ok, 10}, 900, pool)

      plug =
        router(self(), %{
          "fast.test" => {429, ""},
          "second.test" => {200, fixture("challenge_anubis.html")},
          "third.test" => {200, fixture("results_duckduckgo.html")}
        })

      assert {:ok, hits} =
               search("elixir genserver timeout",
                 instances: ["https://third.test", "https://second.test", "https://fast.test"],
                 pool: pool,
                 req_options: [plug: plug]
               )

      assert length(hits) == 8
      assert hd(hits).url =~ "genserver" or hd(hits).url =~ "GenServer"

      assert_received {:searched, "fast.test", %{"q" => "elixir genserver timeout"}}
      assert_received {:searched, "second.test", _}
      assert_received {:searched, "third.test", _}

      assert Pool.stats("https://fast.test/", pool).last_outcome == :rate_limited
      assert Pool.stats("https://second.test/", pool).last_outcome == :challenge
      assert Pool.stats("https://third.test/", pool).successes == 2

      # Next search starts with the instance that answered.
      assert hd(
               Pool.rank(["https://fast.test/", "https://second.test/", "https://third.test/"],
                 pool: pool
               )
             ) ==
               "https://third.test/"
    end

    test "stops at the first answer with merge: 1", %{pool: pool} do
      measure("https://a.test/", {:ok, 10}, 100, pool)

      plug =
        router(self(), %{
          "a.test" => {200, fixture("results_duckduckgo.html")},
          "b.test" => {200, fixture("results_bing_brave.html")}
        })

      assert {:ok, _hits} =
               search("elixir genserver",
                 instances: ["https://a.test", "https://b.test"],
                 pool: pool,
                 req_options: [plug: plug]
               )

      assert_received {:searched, "a.test", _}
      refute_received {:searched, "b.test", _}
    end

    test "fuses two instances with merge: 2", %{pool: pool} do
      plug =
        router(self(), %{
          "a.test" => {200, fixture("results_duckduckgo.html")},
          "b.test" => {200, fixture("results_bing_brave.html")}
        })

      assert {:ok, hits} =
               search("elixir genserver timeout",
                 instances: ["https://a.test", "https://b.test"],
                 merge: 2,
                 limit: 30,
                 pool: pool,
                 req_options: [plug: plug]
               )

      engines = hits |> Enum.flat_map(& &1.engines) |> Enum.uniq()
      assert "duckduckgo" in engines and "bing" in engines
    end

    test "gives up after :attempts and says what each instance did", %{pool: pool} do
      plug =
        router(self(), %{"a.test" => {403, ""}, "b.test" => {429, ""}, "c.test" => {403, ""}})

      assert {:error, {:upstream, %{reason: :no_searxng_answer, attempts: attempts}}} =
               search("q",
                 instances: ["https://a.test", "https://b.test", "https://c.test"],
                 attempts: 2,
                 pool: pool,
                 req_options: [plug: plug]
               )

      assert length(attempts) == 2
    end

    test "passes search options as SearXNG parameters", %{pool: pool} do
      plug = router(self(), %{"a.test" => {200, fixture("results_duckduckgo.html")}})

      search("zoning",
        instances: ["https://a.test/"],
        time_range: "year",
        language: "en-US",
        format: :html,
        pool: pool,
        req_options: [plug: plug]
      )

      assert_received {:searched, "a.test",
                       %{
                         "q" => "zoning",
                         "time_range" => "year",
                         "language" => "en-US",
                         "categories" => "general"
                       }}
    end

    test "moves past an instance whose results ignore the query", %{pool: pool} do
      measure("https://junk.test/", {:ok, 10}, 100, pool)

      plug =
        router(self(), %{
          "junk.test" => {200, fixture("results_bing_brave.html")},
          "good.test" => {200, fixture("results_duckduckgo.html")}
        })

      assert {:ok, _hits} =
               search("genserver timeout",
                 instances: ["https://junk.test", "https://good.test"],
                 pool: pool,
                 req_options: [plug: plug]
               )

      assert_received {:searched, "junk.test", _}
      assert_received {:searched, "good.test", _}
      assert Pool.stats("https://junk.test/", pool).last_outcome == :irrelevant
      assert Pool.stats("https://junk.test/", pool).cooldown_until == nil
    end

    test "refuses an instance that points at a private network" do
      assert {:error, {:upstream, %{attempts: [{"https://127.0.0.1/", :unsafe_url}]}}} =
               SearXNG.search("q",
                 instances: ["https://127.0.0.1"],
                 pool: Fixtures.start_pool([])
               )
    end

    test "needs instances" do
      assert search("q", instances: []) ==
               {:error, {:invalid_request, %{reason: :no_searxng_instances}}}
    end

    test "is a free built-in provider", %{pool: pool} do
      plug = router(self(), %{"a.test" => {200, fixture("results_duckduckgo.html")}})

      assert {:ok, %Result{provider: :searxng, cost: +0.0, hits: [_ | _]}} =
               Search.run(:searxng, "elixir genserver",
                 instances: ["https://a.test"],
                 pool: pool,
                 url_validator: {Fixtures, :allow_url, []},
                 req_options: [plug: plug]
               )
    end
  end

  describe "rate limits" do
    test "a 429 with Retry-After cools the instance for that long", %{pool: pool} do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "")
      end

      before = System.monotonic_time(:millisecond)

      assert {:error, {:upstream, %{attempts: [{"https://a.test/", :rate_limited}]}}} =
               search("q", instances: ["https://a.test"], pool: pool, req_options: [plug: plug])

      assert %{circuit: :open, cooldown_until: until} = Pool.stats("https://a.test/", pool)
      assert (until - before) in 120_000..121_000
    end

    test "says so when every instance is cooling", %{pool: pool} do
      measure_refusal = fn instance ->
        [lease] = Pool.checkout([instance], 1, pool: pool)
        Pool.record(lease, {:error, :blocked}, 10, pool: pool)
      end

      measure_refusal.("https://a.test/")

      assert search("q", instances: ["https://a.test"], pool: pool) ==
               {:error, {:rate_limited, %{reason: :all_searxng_instances_cooling}}}
    end
  end

  describe "profile/1" do
    test "picks a random current browser profile by default" do
      profiles = for _ <- 1..200, into: MapSet.new(), do: SearXNG.profile(:random)
      assert MapSet.size(profiles) > 5
      assert Enum.all?(profiles, &is_atom/1)
    end

    test "picks from a given list, or uses one profile" do
      assert SearXNG.profile([:firefox_151]) == :firefox_151
      assert SearXNG.profile(:"safari_26.4") == :"safari_26.4"
    end
  end

  describe "proxy/1" do
    test "turns a proxy URL into CloakedReq connect options with basic auth" do
      assert SearXNG.proxy("http://user:p%40ss@proxy.example:8080") ==
               [
                 connect_options: [
                   proxy: {:http, "proxy.example", 8080, []},
                   proxy_headers: [
                     {"proxy-authorization", "Basic " <> Base.encode64("user:p@ss")}
                   ]
                 ]
               ]

      assert SearXNG.proxy(nil) == []
    end
  end
end
