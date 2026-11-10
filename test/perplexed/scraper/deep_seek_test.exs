defmodule Perplexed.Scraper.DeepSeekTest do
  # Mutates `config :perplexed` credentials.
  use ExUnit.Case, async: false

  alias Perplexed.{Document, Fixtures, Scrape}
  alias Perplexed.Scraper.DeepSeek

  setup do
    restore =
      Fixtures.put_config(deepseek_api_key: "ds-key", url_validator: {Fixtures, :allow_url, []})

    on_exit(restore)
  end

  defp markdown, do: "# Visiting\n\n" <> Fixtures.readable_text()

  test "fetches the page as Markdown and bills a DeepSeek fetch" do
    plug = Fixtures.json_plug(self(), 200, %{"title" => "Visiting", "content" => markdown()})

    assert {:ok, %Document{tier: :deepseek, cost: 0.00075, markdown: "# Visiting" <> _}} =
             Scrape.run("https://museum.example.org/visit",
               ladder: [:deepseek],
               req_options: [plug: plug]
             )

    assert_received {:request, "/v1/tools/fetch", %{"url" => "https://museum.example.org/visit"}}
  end

  test "no usable content lets the ladder go on instead of ending it" do
    plug =
      Fixtures.plug(404, ~s({"error": {"message": "no usable content"}}), [
        {"content-type", "application/json"}
      ])

    assert DeepSeek.scrape("https://x.example/", req_options: [plug: plug]) ==
             {:error, :no_content}

    assert DeepSeek.scrape("https://x.example/",
             req_options: [plug: Fixtures.json_plug(self(), 200, %{"content" => ""})]
           ) == {:error, :no_content}
  end

  test "maps DeepSeek statuses to ladder outcomes" do
    for {status, message, outcome} <- [
          {401, "bad key", :authentication},
          {402, "Insufficient Balance", :quota_exhausted},
          {403, "rejected by security policy", :blocked},
          {404, "no usable content", :no_content},
          {429, "slow down", :rate_limited},
          {500, "server error", :upstream},
          {504, "downstream timeout", :upstream}
        ] do
      body = Jason.encode!(%{"error" => %{"message" => message}})
      plug = Fixtures.plug(status, body, [{"content-type", "application/json"}])

      assert DeepSeek.scrape("https://x.example/", req_options: [plug: plug, retry: false]) ==
               {:error, outcome},
             "#{status}"
    end
  end

  test "a key DeepSeek rejects lets the ladder go on to the next rung" do
    reject =
      Fixtures.plug(402, ~s({"error": {"message": "Insufficient Balance"}}), [
        {"content-type", "application/json"}
      ])

    assert {:error, {:unreadable, %{attempts: [deepseek: :quota_exhausted], cost: +0.0}}} =
             Scrape.run("https://museum.example.org/visit",
               ladder: [:deepseek],
               req_options: [plug: reject, retry: false]
             )
  end

  test "is configured by the setting or per-call credentials" do
    on_exit(Fixtures.put_config(deepseek_api_key: nil))
    refute DeepSeek.configured?([])
    assert DeepSeek.configured?(credentials: [deepseek_api_key: "ds"])
  end
end
