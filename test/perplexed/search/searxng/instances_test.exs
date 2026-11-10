defmodule Perplexed.Search.SearXNG.InstancesTest do
  use ExUnit.Case, async: true

  alias Perplexed.Fixtures
  alias Perplexed.Search.SearXNG
  alias Perplexed.Search.SearXNG.{Directory, Instances, Pool}

  @fixtures Path.expand("../../../fixtures/searxng", __DIR__)

  @allow {Fixtures, :allow_url, []}

  @start_page ~s(<html><head><meta name="generator" content="searxng/2026.11.9"></head>
                 <body><form id="search" action="/search"></form></body></html>)

  defp instance(median, cidr) do
    %{
      "network_type" => "normal",
      "http" => %{"status_code" => 200},
      "timing" => %{"search" => %{"success_percentage" => 100.0, "all" => %{"median" => median}}},
      "network" => %{"ips" => %{"192.0.2.1" => %{"asn_cidr" => cidr}}}
    }
  end

  defp directory,
    do: %{
      "instances" => %{
        "https://alive.test/" => instance(0.9, "192.0.2.0/24"),
        "https://walled.test/" => instance(0.4, "192.0.2.0/24"),
        "https://refusing.test/" => instance(0.5, "198.51.100.0/24"),
        "https://down.test/" => instance(0.6, "198.51.100.0/24")
      },
      "cidrs" => %{
        "192.0.2.0/24" => %{"network_country" => "DE"},
        "198.51.100.0/24" => %{"network_country" => "US"}
      }
    }

  # searx.space plus one start page per instance; reports each request.
  defp network(test_pid, overrides \\ %{}) do
    routes =
      Map.merge(
        %{
          "searx.space" => fn conn -> Req.Test.json(conn, directory()) end,
          "alive.test" => &Plug.Conn.send_resp(&1, 200, @start_page),
          "walled.test" =>
            &Plug.Conn.send_resp(
              &1,
              200,
              File.read!(Path.join(@fixtures, "challenge_anubis.html"))
            ),
          "refusing.test" => &Plug.Conn.send_resp(&1, 429, ""),
          "down.test" => &Plug.Conn.send_resp(&1, 502, "")
        },
        overrides
      )

    fn conn ->
      send(test_pid, {:requested, conn.host, conn.request_path})
      Map.fetch!(routes, conn.host).(conn)
    end
  end

  setup do
    pool = :"pool_#{System.unique_integer([:positive])}"
    start_supervised!({Pool, name: pool})
    %{pool: pool}
  end

  describe "Directory.probe/2 and discover/1" do
    test "classifies start pages and keeps only live SearXNG instances", %{pool: pool} do
      plug = network(self())
      {:ok, entries} = Directory.fetch(url_validator: @allow, req_options: [plug: plug])

      statuses =
        entries
        |> Directory.probe(url_validator: @allow, req_options: [plug: plug])
        |> Map.new(&{&1.url, &1.probe.status})

      assert statuses == %{
               "https://alive.test/" => :alive,
               "https://walled.test/" => :challenge,
               "https://refusing.test/" => :blocked,
               "https://down.test/" => :down
             }

      assert {:ok, [%{url: "https://alive.test/", probe: %{status: :alive}}]} =
               Directory.discover(url_validator: @allow, req_options: [plug: plug], pool: pool)

      # The prior is searx.space's median plus our round trip.
      assert Pool.stats("https://alive.test/", pool).prior_ms >= 900
    end

    test "probes the start page, never a search", %{pool: pool} do
      {:ok, _live} =
        Directory.discover(
          url_validator: @allow,
          req_options: [plug: network(self())],
          pool: pool
        )

      assert_received {:requested, "alive.test", "/"}
      refute_received {:requested, _host, "/search"}
    end

    test "probe: false keeps every listed instance", %{pool: pool} do
      assert {:ok, entries} =
               Directory.discover(
                 probe: false,
                 url_validator: @allow,
                 req_options: [plug: network(self())],
                 pool: pool
               )

      assert length(entries) == 4
    end

    test "filters by country before probing", %{pool: pool} do
      assert {:ok, [%{url: "https://alive.test/"}]} =
               Directory.discover(
                 countries: ["DE"],
                 url_validator: @allow,
                 req_options: [plug: network(self())],
                 pool: pool
               )

      refute_received {:requested, "refusing.test", _}
    end
  end

  describe "Instances store" do
    setup %{pool: pool} do
      store = :"store_#{System.unique_integer([:positive])}"

      %{
        store: store,
        start: &start_supervised!({Instances, [name: store] ++ &1}, id: store),
        pool: pool
      }
    end

    test "discovers on first use, then serves from memory", %{
      store: store,
      start: start,
      pool: pool
    } do
      start.(discovery: [url_validator: @allow, req_options: [plug: network(self())], pool: pool])

      assert Instances.urls(store: store) == ["https://alive.test/"]
      assert_received {:requested, "searx.space", _}

      assert Instances.urls(store: store) == ["https://alive.test/"]
      refute_received {:requested, "searx.space", _}

      assert %{count: 1, refreshing?: false, last_error: nil, refreshed_at: %DateTime{}} =
               Instances.status(store: store)
    end

    test "concurrent first uses share one discovery", %{store: store, start: start, pool: pool} do
      start.(discovery: [url_validator: @allow, req_options: [plug: network(self())], pool: pool])

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Instances.urls(store: store) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.uniq(results) == [["https://alive.test/"]]
      assert_received {:requested, "searx.space", _}
      refute_received {:requested, "searx.space", _}
    end

    test "an empty discovery is remembered until the next refresh", %{
      store: store,
      start: start,
      pool: pool
    } do
      empty =
        network(self(), %{
          "searx.space" => fn conn -> Req.Test.json(conn, %{"instances" => %{}}) end
        })

      start.(discovery: [url_validator: @allow, req_options: [plug: empty], pool: pool])

      assert Instances.urls(store: store) == []
      assert Instances.urls(store: store) == []

      assert_received {:requested, "searx.space", _}
      refute_received {:requested, "searx.space", _}
    end

    test "a failed first discovery answers at once and is not retried per call", %{
      store: store,
      start: start,
      pool: pool
    } do
      down = network(self(), %{"searx.space" => &Plug.Conn.send_resp(&1, 503, "")})

      start.(
        discovery: [url_validator: @allow, req_options: [plug: down, retry: false], pool: pool]
      )

      assert Instances.urls(store: store) == []
      assert Instances.urls(store: store) == []
      assert_received {:requested, "searx.space", _}
      refute_received {:requested, "searx.space", _}

      assert %{last_error: {:upstream, %{status: 503}}, refreshing?: false} =
               Instances.status(store: store)
    end

    @tag capture_log: true
    test "a crashing discovery answers its waiters and is recorded", %{
      store: store,
      start: start,
      pool: pool
    } do
      crash = network(self(), %{"searx.space" => fn _conn -> raise "directory exploded" end})

      start.(
        discovery: [url_validator: @allow, req_options: [plug: crash, retry: false], pool: pool]
      )

      assert Instances.urls(store: store) == []
      assert %{last_error: {:discovery_crashed, _}} = Instances.status(store: store)
    end

    test "a discovery slower than await_ms leaves the caller with nothing, not an exit", %{
      store: store,
      start: start,
      pool: pool
    } do
      slow =
        network(self(), %{
          "searx.space" => fn conn -> Process.sleep(300) && Req.Test.json(conn, directory()) end
        })

      start.(discovery: [url_validator: @allow, req_options: [plug: slow], pool: pool])

      assert Instances.urls(store: store, await_ms: 20) == []
    end

    test "a failed refresh keeps the last good list", %{store: store, start: start, pool: pool} do
      test_pid = self()
      {:ok, flaky} = Agent.start_link(fn -> :up end)

      directory = fn conn ->
        case Agent.get(flaky, & &1) do
          :up -> Req.Test.json(conn, directory())
          :down -> Plug.Conn.send_resp(conn, 503, "")
        end
      end

      start.(
        discovery: [
          url_validator: @allow,
          req_options: [plug: network(test_pid, %{"searx.space" => directory}), retry: false],
          pool: pool
        ]
      )

      assert Instances.urls(store: store) == ["https://alive.test/"]

      Agent.update(flaky, fn _ -> :down end)
      assert [%{url: "https://alive.test/"}] = Instances.refresh(store: store, await: true)
      assert %{count: 1, last_error: {:upstream, %{status: 503}}} = Instances.status(store: store)
    end

    test "feeds `instances: :auto` searches", %{store: store, start: start, pool: pool} do
      results = File.read!(Path.join(@fixtures, "results_duckduckgo.html"))

      plug =
        network(self(), %{
          "alive.test" => fn
            %{request_path: "/search"} = conn -> Plug.Conn.send_resp(conn, 200, results)
            conn -> Plug.Conn.send_resp(conn, 200, @start_page)
          end
        })

      start.(discovery: [url_validator: @allow, req_options: [plug: plug], pool: pool])

      assert {:ok, [_ | _]} =
               SearXNG.search("elixir genserver timeout",
                 instances: :auto,
                 store: store,
                 pool: pool,
                 jitter: 0,
                 min_interval_ms: 0,
                 url_validator: @allow,
                 req_options: [plug: plug]
               )

      assert_received {:requested, "alive.test", "/search"}
    end
  end
end
