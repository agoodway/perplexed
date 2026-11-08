defmodule Perplexed.Scraper.Impersonated do
  @moduledoc """
  HTTP through `CloakedReq` (Rust wreq) as a `Perplexed.Scraper`: the
  request carries a real browser's TLS and HTTP/2 fingerprint and headers,
  which gets past sites that refuse plain clients on that signal alone.

  It does not run JavaScript, so it is only worth trying after a refusal, an
  unexpected HTTP status, a bot challenge or a transport failure, never after
  a JavaScript shell.
  `:impersonate` picks the profile, default `:chrome_146`.
  """

  @behaviour Perplexed.Scraper

  alias Perplexed.Scraper.Http

  @profile :chrome_146
  @retries_on [:blocked, :challenge, :http_error, :download_failed, :timeout, :tls_chain_error]

  @impl true
  def scrape(url, opts),
    do: Http.scrape(url, opts, impersonate: Keyword.get(opts, :impersonate, @profile))

  @impl true
  def retries?(outcome), do: outcome in @retries_on
end
