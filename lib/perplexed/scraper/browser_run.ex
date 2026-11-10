defmodule Perplexed.Scraper.BrowserRun do
  @moduledoc """
  Cloudflare Browser Run `/markdown` quick action as a `Perplexed.Scraper`:
  loads the URL in headless Chrome, runs its JavaScript, and returns the
  rendered page as Markdown.

  It renders; it does not get past bot protection, because Browser Run
  always identifies itself as a bot. Billing is browser time (10 hours a
  month on Workers Paid, then $0.09 an hour); the `x-browser-ms-used` header
  reports each call's time, kept on the document as `browser_ms`.

  Needs `config :perplexed, cloudflare_account_id:` and a
  `cloudflare_api_token:` with Browser Run Edit.
  """

  @behaviour Perplexed.Scraper

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Document, Http, Scraper}

  @base_url "https://api.cloudflare.com/client/v4/accounts"
  @timeout_ms 60_000
  # $0.09 per browser hour past the 10 included a month on Workers Paid, as
  # of 2026-11-10 (developers.cloudflare.com/browser-rendering/pricing).
  @usd_per_browser_ms 0.09 / 3_600_000

  @impl true
  def cost(%Document{browser_ms: ms}, _opts), do: ms * @usd_per_browser_ms

  @impl true
  def configured?(opts),
    do: Config.credentials?([:cloudflare_account_id, :cloudflare_api_token], :browser_run, opts)

  @impl true
  def scrape(url, opts) when is_present(url) do
    with {:ok, account_id} <- Config.credential(:cloudflare_account_id, :browser_run, opts),
         {:ok, token} <- Config.credential(:cloudflare_api_token, :browser_run, opts),
         {:ok, response} <-
           Http.post_json(
             :browser_run,
             "#{@base_url}/#{account_id}/browser-run/markdown",
             %{"url" => url, "gotoOptions" => %{"waitUntil" => "networkidle2"}},
             token,
             receive_timeout: Scraper.time_left(opts, @timeout_ms),
             req_options: Keyword.get(opts, :req_options, [])
           ) do
      document(response)
    else
      {:error, {reason, _metadata}} -> {:error, reason}
    end
  end

  defp document(%Req.Response{body: %{"success" => true, "result" => markdown}} = response)
       when is_binary(markdown) do
    {:ok,
     %Document{
       markdown: markdown,
       content_type: "text/markdown",
       browser_ms: browser_ms(response)
     }, nil}
  end

  defp document(%Req.Response{}), do: {:error, :invalid_response}

  defp browser_ms(response) do
    with [value | _rest] <- Req.Response.get_header(response, "x-browser-ms-used"),
         {ms, _rest} <- Integer.parse(value) do
      ms
    else
      _missing -> 0
    end
  end
end
