defmodule Perplexed.Search.SearXNG.DirectoryTest do
  use ExUnit.Case, async: true

  alias Perplexed.Search.SearXNG.{Directory, Pool}

  defp instance(median, opts) do
    %{
      "network_type" => Keyword.get(opts, :network, "normal"),
      "http" => %{"status_code" => Keyword.get(opts, :status, 200)},
      "timing" => %{
        "search" => %{
          "success_percentage" => Keyword.get(opts, :success, 100.0),
          "all" => %{"median" => median},
          "working_engine_names" => ["duckduckgo"]
        }
      },
      "network" => %{"ips" => %{"192.0.2.1" => %{"asn_cidr" => Keyword.fetch!(opts, :cidr)}}}
    }
  end

  defp body,
    do: %{
      "instances" => %{
        "https://de.example/" => instance(0.8, cidr: "192.0.2.0/24"),
        "https://us.example/" => instance(1.4, cidr: "198.51.100.0/24"),
        "https://slow.example/" => instance(4.0, cidr: "198.51.100.0/24"),
        "https://flaky.example/" => instance(0.5, cidr: "192.0.2.0/24", success: 40.0),
        "https://onion.example/" => instance(0.5, cidr: "192.0.2.0/24", network: "tor"),
        "https://down.example/" => instance(0.5, cidr: "192.0.2.0/24", status: 502)
      },
      "cidrs" => %{
        "192.0.2.0/24" => %{"network_country" => "DE"},
        "198.51.100.0/24" => %{"network_country" => "US"}
      }
    }

  test "keeps healthy clearnet instances, fastest first" do
    assert body() |> Directory.entries() |> Directory.urls() ==
             ["https://de.example/", "https://us.example/", "https://slow.example/"]
  end

  test "keeps only plain https instances" do
    body = %{
      "instances" => %{
        "https://ok.example/" => instance(0.5, cidr: "192.0.2.0/24"),
        "http://cleartext.example/" => instance(0.5, cidr: "192.0.2.0/24"),
        "https://user:pass@creds.example/" => instance(0.5, cidr: "192.0.2.0/24"),
        "https://query.example/?a=1" => instance(0.5, cidr: "192.0.2.0/24")
      }
    }

    assert body |> Directory.entries() |> Directory.urls() == ["https://ok.example/"]
  end

  test "a probe never contacts an instance on a private network" do
    entry = %{url: "https://127.0.0.1/", countries: [], median_ms: 100, engines: []}
    assert [%{probe: %{status: :blocked}}] = Directory.probe([entry])
  end

  test "filters by country and speed" do
    assert [%{url: "https://us.example/", countries: ["US"], median_ms: 1400}] =
             Directory.entries(body(), countries: ["us"], max_median_ms: 2000)
  end

  test "seeds the pool with searx.space medians" do
    name = :"pool_#{System.unique_integer([:positive])}"
    start_supervised!({Pool, name: name})

    body() |> Directory.entries() |> Directory.seed(pool: name)
    assert Pool.stats("https://us.example/", name).prior_ms == 1400
  end

  test "fetches the directory" do
    plug = fn conn -> Req.Test.json(conn, body()) end
    assert {:ok, [_, _, _]} = Directory.fetch(req_options: [plug: plug])
  end
end
