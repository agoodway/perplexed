defmodule Perplexed.Scraper.FirecrawlTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Document, Fixtures}
  alias Perplexed.Scraper.Firecrawl

  @url "https://example.org/page"

  defp opts(plug, extra \\ []),
    do: [credentials: [firecrawl_api_key: "fc-key"], req_options: [plug: plug]] ++ extra

  defp success(data), do: %{"success" => true, "data" => data}

  describe "scrape/2 budget" do
    test "a near deadline still asks Firecrawl for at least one second" do
      plug = Fixtures.json_plug(self(), 200, success(%{"markdown" => "text"}))
      deadline = System.monotonic_time(:millisecond) + 2_000

      assert {:ok, _document, nil} = Firecrawl.scrape(@url, opts(plug, deadline: deadline))
      assert_received {:request, _path, %{"timeout" => timeout}}
      assert timeout >= 1_000
    end
  end

  describe "scrape/2 documents" do
    test "returns the markdown with the metadata url as the final url" do
      payload =
        success(%{
          "markdown" => "# Page",
          "metadata" => %{"url" => "https://example.org/final", "sourceURL" => @url}
        })

      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok, %Document{markdown: "# Page", content_type: "text/markdown"} = document, nil} =
               Firecrawl.scrape(@url, opts(plug))

      assert document.final_url == "https://example.org/final"
    end

    test "falls back to sourceURL when metadata has no url" do
      payload = success(%{"markdown" => "text", "metadata" => %{"sourceURL" => @url}})
      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok, %Document{final_url: @url}, nil} = Firecrawl.scrape(@url, opts(plug))
    end

    test "has no final url when the metadata is missing" do
      plug = Fixtures.json_plug(self(), 200, success(%{"markdown" => "text"}))

      assert {:ok, %Document{markdown: "text", final_url: nil}, nil} =
               Firecrawl.scrape(@url, opts(plug))
    end

    test "success false is an invalid response" do
      plug = Fixtures.json_plug(self(), 200, %{"success" => false, "error" => "nope"})
      assert Firecrawl.scrape(@url, opts(plug)) == {:error, :invalid_response}
    end

    test "a reply without markdown is an invalid response" do
      plug = Fixtures.json_plug(self(), 200, success(%{"html" => "<p>x</p>"}))
      assert Firecrawl.scrape(@url, opts(plug)) == {:error, :invalid_response}
    end
  end

  describe "scrape/2 failures" do
    test "402 is quota exhausted" do
      plug = Fixtures.json_plug(self(), 402, %{"error" => "Payment required"})
      assert Firecrawl.scrape(@url, opts(plug)) == {:error, :quota_exhausted}
    end

    test "401 is authentication" do
      plug = Fixtures.json_plug(self(), 401, %{"error" => "Unauthorized"})
      assert Firecrawl.scrape(@url, opts(plug)) == {:error, :authentication}
    end

    test "500 is upstream" do
      plug = Fixtures.json_plug(self(), 500, %{"error" => "boom"})
      req_options = [plug: plug, retry: false]

      assert Firecrawl.scrape(
               @url,
               credentials: [firecrawl_api_key: "fc-key"],
               req_options: req_options
             ) == {:error, :upstream}
    end

    test "a missing key is authentication, without a request" do
      plug = fn _conn -> flunk("no request expected") end

      assert Firecrawl.scrape(@url,
               credentials: [firecrawl_api_key: ""],
               req_options: [plug: plug]
             ) ==
               {:error, :authentication}
    end
  end

  describe "scrape/2 request" do
    test "asks for main-content markdown with the default cache age" do
      plug = Fixtures.json_plug(self(), 200, success(%{"markdown" => "text"}))
      assert {:ok, _document, nil} = Firecrawl.scrape(@url, opts(plug))

      assert_received {:request, "/v2/scrape", body}
      assert body["url"] == @url
      assert body["formats"] == ["markdown"]
      assert body["onlyMainContent"] == true
      assert body["maxAge"] == 86_400_000
    end

    test "max_age_ms overrides the cache age" do
      plug = Fixtures.json_plug(self(), 200, success(%{"markdown" => "text"}))
      assert {:ok, _document, nil} = Firecrawl.scrape(@url, opts(plug, max_age_ms: 0))

      assert_received {:request, _path, %{"maxAge" => 0}}
    end

    test "keeps its timeout budget under the scrape deadline" do
      plug = Fixtures.json_plug(self(), 200, success(%{"markdown" => "text"}))
      deadline = System.monotonic_time(:millisecond) + 20_000
      assert {:ok, _document, nil} = Firecrawl.scrape(@url, opts(plug, deadline: deadline))

      assert_received {:request, _path, %{"timeout" => timeout}}
      assert timeout <= 15_000 and timeout >= 1_000
    end
  end

  describe "cost/2" do
    test "is one credit per page" do
      assert_in_delta Firecrawl.cost(%Document{}, []), 0.00099, 1.0e-9
    end
  end
end
