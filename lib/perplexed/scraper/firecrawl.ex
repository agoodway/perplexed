defmodule Perplexed.Scraper.Firecrawl do
  @moduledoc """
  Firecrawl v2 scrape as a `Perplexed.Scraper`.

  Firecrawl renders JavaScript and handles many protected sites, at one
  credit per HTML page, priced by `credit_usd/0` (the `firecrawl_credit_usd`
  setting). Accepts a cached copy up to a day old (`:max_age_ms`).

  Firecrawl also reads PDFs, at one credit per PDF page. A ladder hands it a
  PDF the free tiers could not convert (no `Perplexed.PdfConverter`
  configured) only with `firecrawl_pdf: true` in the settings; otherwise a
  PDF ends the climb unread rather than billing per page. With a local
  converter configured, PDFs never reach Firecrawl.

  Needs `config :perplexed, firecrawl_api_key:`.
  """

  @behaviour Perplexed.Scraper

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Document, Http, Scraper}

  @url "https://api.firecrawl.dev/v2/scrape"
  @timeout_ms 60_000
  @max_age_ms 86_400_000
  # One credit at the Standard plan's allowance rate ($99 / 100,000 credits),
  # as of 2026-11-10 (firecrawl.dev/pricing).
  @default_credit_usd 0.00099

  @impl true
  def cost(%Document{}, _opts), do: credit_usd()

  @doc """
  USD per Firecrawl credit: the `firecrawl_credit_usd` setting, else
  #{@default_credit_usd} (the Standard plan's $99 for 100,000). Set it to
  what your plan pays, for example 0.0038 on Hobby, or about 0.0025 for
  credits bought past a Standard allowance (all as of 2026-11-10). A
  scraped page is one credit, a PDF one per page; a search is two (see
  `Perplexed.Search.Firecrawl`).
  """
  @spec credit_usd() :: float()
  def credit_usd, do: (Config.get(:firecrawl_credit_usd) || @default_credit_usd) * 1.0

  @impl true
  def retries?(:unsupported), do: Config.get(:firecrawl_pdf, false) == true
  def retries?(_outcome), do: true

  @impl true
  def configured?(opts), do: Config.credentials?(:firecrawl_api_key, :firecrawl, opts)

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
