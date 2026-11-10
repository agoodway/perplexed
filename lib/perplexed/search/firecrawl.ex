defmodule Perplexed.Search.Firecrawl do
  @moduledoc """
  Firecrawl v2 search as a `Perplexed.Search` provider.

  Never sends `scrapeOptions`, so a search costs two credits per ten results
  and returns snippets only; scrape pages with `Perplexed.Scrape` instead.
  Priced at two credits of `Perplexed.Scraper.Firecrawl.credit_usd/0` (the
  `firecrawl_credit_usd` setting).
  `:country` defaults to `"US"`.

  Needs `config :perplexed, firecrawl_api_key:`.
  """

  @behaviour Perplexed.Search

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Http}
  alias Perplexed.Scraper.Firecrawl, as: FirecrawlScraper
  alias Perplexed.Search.Hit

  @url "https://api.firecrawl.dev/v2/search"
  @default_limit 8
  @max_query_length 500
  @timeout_ms 30_000
  # Two credits per ten results, as of 2026-11-10 (firecrawl.dev/pricing);
  # perplexed asks for at most ten.
  @credits_per_search 2

  @impl true
  def price(_opts), do: @credits_per_search * FirecrawlScraper.credit_usd()

  @impl true
  def search(query, opts) when is_present(query) do
    body = %{
      "query" => query |> String.trim() |> String.slice(0, @max_query_length),
      "limit" => Keyword.get(opts, :limit, @default_limit),
      "country" => Keyword.get(opts, :country, "US")
    }

    with {:ok, key} <- Config.credential(:firecrawl_api_key, :firecrawl, opts) do
      :firecrawl
      |> Http.post_json(@url, body, key,
        receive_timeout: @timeout_ms,
        req_options: Keyword.get(opts, :req_options, [])
      )
      |> hits()
    end
  end

  def search(_query, _opts), do: {:error, {:invalid_request, %{reason: :empty_query}}}

  defp hits({:ok, %Req.Response{body: %{"success" => true, "data" => %{"web" => web}}}})
       when is_list(web),
       do: {:ok, web |> Enum.filter(&is_present(&1["url"])) |> Enum.map(&hit/1)}

  defp hits({:ok, %Req.Response{body: %{"success" => true, "data" => data}}}) when is_list(data),
    do: {:ok, data |> Enum.filter(&is_present(&1["url"])) |> Enum.map(&hit/1)}

  defp hits({:ok, %Req.Response{body: body}}), do: Http.invalid_response(:firecrawl, @url, body)
  defp hits({:error, _reason} = error), do: error

  defp hit(%{"url" => url} = item),
    do: %Hit{
      url: url,
      title: item["title"],
      description: item["description"],
      provider: :firecrawl
    }
end
