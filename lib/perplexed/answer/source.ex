defmodule Perplexed.Answer.Source do
  @moduledoc """
  One page an answer was written from. `number` is its citation number;
  `tier` is the scraper that read it and `cost` what reading it cost.
  """

  defstruct [:number, :url, :title, :relevance, :tier, :cost]

  @type t :: %__MODULE__{
          number: pos_integer(),
          url: String.t(),
          title: String.t() | nil,
          relevance: float(),
          tier: atom(),
          cost: float()
        }
end
