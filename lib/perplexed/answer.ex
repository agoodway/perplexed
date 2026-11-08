defmodule Perplexed.Answer do
  @moduledoc """
  The result of `Perplexed.answer/2`.

    * `answer` - the summary text, with inline `[n]` citations, or the
      validated object when the call passed a `:schema`.
    * `sources` - the pages the summary was written from, numbered as the
      citations number them (`Perplexed.Answer.Source`).
    * `cited` - the source numbers the text answer actually cites.
    * `considered` - every unique search hit, with its relevance score, the
      ranker's reason, and what happened to it (`Perplexed.Answer.Candidate`).
    * `queries` - the search queries that ran.
    * `usage` - token counts and USD cost by step; `trace` - one entry per
      model call, search and scrape.
  """

  alias Perplexed.Answer.{Candidate, Source}

  defstruct [
    :query,
    :answer,
    :model,
    queries: [],
    sources: [],
    cited: [],
    considered: [],
    usage: %{},
    trace: []
  ]

  @type t :: %__MODULE__{
          query: String.t(),
          answer: String.t() | map(),
          model: Perplexed.model_spec(),
          queries: [String.t()],
          sources: [Source.t()],
          cited: [pos_integer()],
          considered: [Candidate.t()],
          usage: map(),
          trace: [map()]
        }
end
