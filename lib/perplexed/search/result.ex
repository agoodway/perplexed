defmodule Perplexed.Search.Result do
  @moduledoc """
  One search call: the hits, the provider that answered, and what it cost.

  `cost` is the provider's list price in USD for this request. A request
  that returned nothing still costs that price, unless the provider reports
  empty results as free (`c:Perplexed.Search.free_when_empty?/0`).
  `scrape_cost` is the summed cost of the hits' documents when the search
  ran with `scrape: true`. `total_cost` is both together.
  """

  defstruct [:query, :provider, hits: [], cost: 0.0, scrape_cost: 0.0, total_cost: 0.0]

  @type t :: %__MODULE__{
          query: String.t(),
          provider: Perplexed.Search.spec(),
          hits: [Perplexed.Search.Hit.t()],
          cost: float(),
          scrape_cost: float(),
          total_cost: float()
        }
end
