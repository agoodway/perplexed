defmodule Perplexed.Search.Hit do
  @moduledoc """
  One search result, normalized across providers.

  `description` is the provider's text about the page for this query: a
  snippet, highlights, or a long summary, depending on the provider.
  `content` is page text when the provider returns it (DeepSeek with
  `need_content: true`), otherwise `nil`. `document` is the scraped page when
  the search ran with `scrape: true` and the page was readable; otherwise
  `scrape_error` says why it was not (for example
  `{:unreadable, %{attempts: [direct: :blocked, impersonated: :blocked], cost: 0.0}}`).
  """

  defstruct [
    :url,
    :title,
    :description,
    :content,
    :published_at,
    :provider,
    :document,
    :scrape_error
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          content: String.t() | nil,
          published_at: String.t() | nil,
          provider: atom(),
          document: Perplexed.Document.t() | nil,
          scrape_error: term()
        }
end
