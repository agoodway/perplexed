defmodule Perplexed.Search.Result do
  @moduledoc """
  One search call: the hits, the provider that answered, and what it cost.

  `provider` is the name of the provider that answered (a built-in name or
  the module, never a spec's options). `cost` is its list price in USD for
  this request, or for a fallback chain the sum of every attempt's cost. A
  request that returned nothing still costs that price, unless the provider
  reports empty results as free (`c:Perplexed.Search.free_when_empty?/0`).
  `scrape_cost` is the summed cost of the hits' documents when the search
  ran with `scrape: true`. `total_cost` is both together. `attempts` lists
  each provider a fallback chain tried (see `Perplexed.Search.Fallback`),
  and is empty for a single provider.
  """

  alias Perplexed.Search
  alias Perplexed.Search.{Fallback, Hit}

  defstruct [
    :query,
    :provider,
    hits: [],
    cost: 0.0,
    scrape_cost: 0.0,
    total_cost: 0.0,
    attempts: []
  ]

  @type t :: %__MODULE__{
          query: String.t(),
          provider: Search.spec(),
          hits: [Hit.t()],
          cost: float(),
          scrape_cost: float(),
          total_cost: float(),
          attempts: [Fallback.attempt()]
        }
end
