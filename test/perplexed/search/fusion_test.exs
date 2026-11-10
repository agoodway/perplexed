defmodule Perplexed.Search.FusionTest do
  use ExUnit.Case, async: true

  alias Perplexed.Search.{Fusion, Hit}

  doctest Fusion

  defp hit(url, opts \\ []) do
    %Hit{
      url: url,
      title: Keyword.get(opts, :title, "Elixir GenServer timeout"),
      description: Keyword.get(opts, :description),
      engines: Keyword.get(opts, :engines, ["bing"]),
      provider: :searxng
    }
  end

  describe "url_key/1" do
    test "treats www, trailing slashes, fragments and tracking params as the same page" do
      assert Fusion.url_key("https://www.example.com/page/") ==
               Fusion.url_key("http://example.com/page#section")

      assert Fusion.url_key("https://example.com/p?utm_source=a&fbclid=b&id=7") ==
               Fusion.url_key("https://example.com/p?id=7")
    end

    test "keeps parameters that select different content" do
      refute Fusion.url_key("https://example.com/p?id=7") ==
               Fusion.url_key("https://example.com/p?id=8")
    end
  end

  describe "fuse/2" do
    test "merges duplicates across lists, keeping every engine and the longest description" do
      a = [hit("https://www.example.com/a/", engines: ["bing"], description: "short")]
      b = [hit("https://example.com/a", engines: ["brave"], description: "a longer snippet")]

      assert [merged] = Fusion.fuse([a, b], lexical_weight: 0)
      assert merged.engines == ["bing", "brave"]
      assert merged.description == "a longer snippet"
    end

    test "ranks a page several lists agree on above one list's top hit" do
      only_first = hit("https://solo.example/")
      shared = hit("https://shared.example/")

      fused =
        Fusion.fuse([[only_first, shared], [shared], [shared]], lexical_weight: 0)

      assert Enum.map(fused, & &1.url) == ["https://shared.example/", "https://solo.example/"]
    end

    test "boosts a hit more engines agree on at the same position" do
      one = hit("https://one.example/", engines: ["bing"])
      three = hit("https://three.example/", engines: ["bing", "brave", "duckduckgo"])

      assert [%{url: "https://three.example/"}, _] =
               Fusion.fuse([[one], [three]], lexical_weight: 0)
    end

    test "pushes a hit sharing no query terms below relevant ones" do
      junk = hit("https://junk.example/", title: "Ονειροκρίτης γιαγιά", engines: ["bing"])
      relevant = hit("https://hexdocs.pm/elixir/GenServer.html", title: "GenServer behaviour")

      assert [%{url: "https://hexdocs.pm/elixir/GenServer.html"}, %{url: "https://junk.example/"}] =
               Fusion.fuse([[junk, relevant]], query: "elixir genserver timeout")
    end

    test "with k: 0 the top spot weighs more than with RRF's k: 60" do
      top = hit("https://top.example/")
      second = hit("https://second.example/")
      lists = [[top, second], [second]]

      assert [%{url: "https://second.example/"} | _] =
               Fusion.fuse(lists, k: 60, lexical_weight: 0)

      assert [%{url: "https://second.example/"} | _] = Fusion.fuse(lists, k: 0, lexical_weight: 0)

      # 1/1 vs 1/2 + 1/1: agreement still wins, but by a narrower margin at k: 0.
      assert Fusion.fuse([[top, second]], k: 0, lexical_weight: 0) |> hd() |> Map.get(:url) ==
               "https://top.example/"
    end

    test "honors :limit" do
      hits = for n <- 1..5, do: hit("https://example.com/#{n}")
      assert length(Fusion.fuse([hits], limit: 3)) == 3
    end
  end

  describe "coverage/2" do
    test "is the share of non-stopword query terms found in the hit" do
      assert Fusion.coverage(
               hit("https://x.example/", title: "GenServer timeout"),
               "the genserver timeout docs"
             ) ==
               2 / 3
    end

    test "is full for a query with no terms" do
      assert Fusion.coverage(hit("https://x.example/"), "the of") == 1.0
    end
  end
end
