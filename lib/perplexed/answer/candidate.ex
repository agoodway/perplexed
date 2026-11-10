defmodule Perplexed.Answer.Candidate do
  @moduledoc """
  One unique search hit an answer considered.

  `relevance` (0 to 1) and `reason` come from the ranking call, which sees
  the title, URL and description, plus the signals the search provider
  gave: publication date, site name, the provider's own relevance score
  and authority tier (DeepSeek), and the engines that agreed on it
  (SearXNG). `content` is page text the provider returned with the hit;
  when it reads well, the answer uses it instead of scraping the page.
  `queries` lists every query that returned the hit. `status` is what
  happened to it:

    * `:used` - scraped and given to the summary.
    * `:unreadable` - kept, but every scraper failed; `scrape_error` says why.
    * `:duplicate` - scraped, but it landed on a page another source
      already covers.
    * `:not_needed` - kept, but `max_sources` was already filled.
    * `:dropped` - ranked below `min_relevance`.
  """

  defstruct [
    :id,
    :url,
    :title,
    :description,
    :relevance,
    :reason,
    :scrape_error,
    :content,
    :published_at,
    queries: [],
    engines: [],
    metadata: %{},
    status: :dropped
  ]

  @type status :: :used | :unreadable | :duplicate | :not_needed | :dropped

  @type t :: %__MODULE__{
          id: pos_integer(),
          url: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          relevance: float() | nil,
          reason: String.t() | nil,
          scrape_error: term(),
          content: String.t() | nil,
          published_at: String.t() | nil,
          queries: [String.t()],
          engines: [String.t()],
          metadata: map(),
          status: status()
        }
end
