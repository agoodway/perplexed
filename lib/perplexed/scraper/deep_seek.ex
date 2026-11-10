defmodule Perplexed.Scraper.DeepSeek do
  @moduledoc """
  DeepSeek Fetch API (`POST /v1/tools/fetch`) as a `Perplexed.Scraper`:
  DeepSeek fetches the URL and returns the page as Markdown.

  Billed $0.75 per 1,000 successful fetches ($0.00075 a page, against
  $0.00099 for `Perplexed.Scraper.Firecrawl`); a fetch that returns no
  content is not billed. Fetching depends on the target site's own access
  policies, and DeepSeek limits fetches per domain as well as per account.
  When it has no usable content for the page the outcome is `:no_content`,
  so the ladder still tries the next rung.

  Needs `config :perplexed, deepseek_api_key:`.
  """

  @behaviour Perplexed.Scraper

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Document, Http, Scraper}

  @url "https://api.deepseek.com/v1/tools/fetch"
  @timeout_ms 30_000
  # $0.75 per 1,000 successful fetches, as of 2026-11-10 (api-docs.deepseek.com).
  @usd_per_page 0.00075

  @impl true
  def cost(%Document{}, _opts), do: @usd_per_page

  @impl true
  def configured?(opts), do: Config.credentials?(:deepseek_api_key, :deepseek, opts)

  @impl true
  def scrape(url, opts) when is_present(url) do
    with {:ok, key} <- Config.credential(:deepseek_api_key, :deepseek, opts),
         {:ok, response} <-
           Http.post_json(:deepseek, @url, %{"url" => url}, key,
             receive_timeout: Scraper.time_left(opts, @timeout_ms),
             req_options: Keyword.get(opts, :req_options, [])
           ) do
      document(response)
    else
      {:error, {reason, metadata}} -> {:error, outcome(reason, metadata)}
    end
  end

  defp document(%Req.Response{body: %{"content" => markdown}}) when is_present(markdown),
    do: {:ok, %Document{markdown: markdown, content_type: "text/markdown"}, nil}

  defp document(%Req.Response{body: %{"content" => _empty}}), do: {:error, :no_content}
  defp document(%Req.Response{}), do: {:error, :invalid_response}

  # DeepSeek answers 404 when it has no usable content for a page that may
  # well exist, so it is not the ladder-ending `:not_found`; its 403 means
  # the page was refused by its security policy, not that our key was.
  defp outcome(:not_found, _metadata), do: :no_content
  defp outcome(:authentication, %{status: 403}), do: :blocked
  defp outcome(reason, _metadata), do: reason
end
