defmodule Perplexed.Scraper.Direct do
  @moduledoc """
  Plain HTTP as a `Perplexed.Scraper`, sending browser-like request headers.
  Free and fast; the first tier of the default ladder.
  """

  @behaviour Perplexed.Scraper

  alias Perplexed.Scraper.Http

  @headers [
    {"user-agent",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
       "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"},
    {"accept", "text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8"},
    {"accept-language", "en-US,en;q=0.9"}
  ]

  @impl true
  def scrape(url, opts), do: Http.scrape(url, opts, headers: @headers)
end
