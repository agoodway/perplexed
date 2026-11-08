defmodule Perplexed.Scraper.BrowserRunTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Document, Fixtures}
  alias Perplexed.Scraper.BrowserRun

  @url "https://example.org/app"

  defp opts(plug),
    do: [
      credentials: [cloudflare_account_id: "acct", cloudflare_api_token: "token"],
      req_options: [plug: plug, retry: false]
    ]

  defp rendered(markdown), do: %{"success" => true, "result" => markdown}

  describe "scrape/2" do
    test "returns the rendered markdown and the browser time from the header" do
      plug = Fixtures.json_plug(self(), 200, rendered("# App"), [{"x-browser-ms-used", "1500"}])

      assert {:ok, %Document{markdown: "# App", content_type: "text/markdown", browser_ms: 1500},
              nil} = BrowserRun.scrape(@url, opts(plug))
    end

    test "a missing time header counts as zero" do
      plug = Fixtures.json_plug(self(), 200, rendered("# App"))
      assert {:ok, %Document{browser_ms: 0}, nil} = BrowserRun.scrape(@url, opts(plug))
    end

    test "a non-numeric time header counts as zero" do
      plug = Fixtures.json_plug(self(), 200, rendered("# App"), [{"x-browser-ms-used", "slow"}])
      assert {:ok, %Document{browser_ms: 0}, nil} = BrowserRun.scrape(@url, opts(plug))
    end

    test "success false is an invalid response" do
      plug = Fixtures.json_plug(self(), 200, %{"success" => false, "result" => "x"})
      assert BrowserRun.scrape(@url, opts(plug)) == {:error, :invalid_response}
    end

    test "waits for the network to go idle" do
      plug = Fixtures.json_plug(self(), 200, rendered("# App"))
      assert {:ok, _document, nil} = BrowserRun.scrape(@url, opts(plug))

      assert_received {:request, path, body}
      assert path == "/client/v4/accounts/acct/browser-run/markdown"
      assert body == %{"url" => @url, "gotoOptions" => %{"waitUntil" => "networkidle2"}}
    end

    test "a missing credential is authentication" do
      plug = fn _conn -> flunk("no request expected") end

      assert BrowserRun.scrape(@url,
               credentials: [cloudflare_account_id: "acct", cloudflare_api_token: ""],
               req_options: [plug: plug]
             ) == {:error, :authentication}
    end
  end

  describe "cost/2" do
    test "bills $0.09 per browser hour" do
      assert_in_delta BrowserRun.cost(%Document{browser_ms: 3_600_000}, []), 0.09, 1.0e-9
      assert_in_delta BrowserRun.cost(%Document{browser_ms: 1_000}, []), 0.000025, 1.0e-9
      assert BrowserRun.cost(%Document{browser_ms: 0}, []) == 0.0
    end
  end
end
