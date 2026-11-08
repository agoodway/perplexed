defmodule Perplexed.Scraper.Firecrawl do
  @moduledoc """
  Firecrawl v2 scrape as a `Perplexed.Scraper`.

  Firecrawl renders JavaScript and handles many protected sites, at one
  credit per HTML page. Its PDF parser stays off, because Firecrawl bills
  PDFs per page; the local scrapers convert PDFs instead. Accepts a cached
  copy up to a day old (`:max_age_ms`).

  Needs `config :perplexed, firecrawl_api_key:`.
  """

  @behaviour Perplexed.Scraper

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Document, Http, Scraper}

  @url "https://api.firecrawl.dev/v2/scrape"
  @timeout_ms 60_000
  @max_age_ms 86_400_000
  # One credit at the Standard plan's allowance rate ($99 / 100k credits).
  @usd_per_page 0.00099

  @impl true
  def cost(%Document{}, _opts), do: @usd_per_page

  @impl true
  def scrape(url, opts) when is_present(url) do
    # Firecrawl's own budget leaves a few seconds of the scrape deadline for
    # the reply to arrive, and the reply wait never outlives the time left.
    left = Scraper.time_left(opts, @timeout_ms + 5_000)
    budget = max(left - 5_000, 1_000)
    receive_timeout = min(budget + 5_000, left)

    body = %{
      "url" => url,
      "formats" => ["markdown"],
      "onlyMainContent" => true,
      "blockAds" => true,
      "maxAge" => Keyword.get(opts, :max_age_ms, @max_age_ms),
      "timeout" => budget
    }

    with {:ok, key} <- Config.credential(:firecrawl_api_key, :firecrawl, opts),
         {:ok, response} <-
           Http.post_json(:firecrawl, @url, body, key,
             receive_timeout: receive_timeout,
             req_options: Keyword.get(opts, :req_options, [])
           ) do
      document(response)
    else
      {:error, {reason, _metadata}} -> {:error, reason}
    end
  end

  defp document(%Req.Response{
         body: %{"success" => true, "data" => %{"markdown" => markdown} = data}
       })
       when is_binary(markdown) do
    metadata = data["metadata"] || %{}

    {:ok,
     %Document{
       markdown: markdown,
       content_type: "text/markdown",
       final_url: metadata["url"] || metadata["sourceURL"]
     }, nil}
  end

  defp document(%Req.Response{}), do: {:error, :invalid_response}
end
