defmodule Perplexed.Document do
  @moduledoc """
  One scraped page as Markdown, with how it was obtained.

  `tier` names the `Perplexed.Scraper` that produced readable text (a
  built-in name such as `:direct`, or a custom scraper's module). `attempts`
  lists every rung tried, in order, with its outcome, so a run shows where
  the ladder escalated. `browser_ms` is Browser Run time when that rung ran.
  `cost` is the USD cost of the rung that produced the document (`0.0` for
  the free direct and impersonated rungs).
  """

  alias Perplexed.Verdict

  defstruct [
    :url,
    :final_url,
    :tier,
    :content_type,
    :markdown,
    attempts: [],
    browser_ms: 0,
    cost: 0.0
  ]

  @type tier :: atom()
  @type outcome :: Verdict.t() | atom()

  @type t :: %__MODULE__{
          url: String.t(),
          final_url: String.t() | nil,
          tier: tier(),
          content_type: String.t() | nil,
          markdown: String.t(),
          attempts: [{tier(), outcome()}],
          browser_ms: non_neg_integer(),
          cost: float()
        }
end
