defmodule Perplexed.Guards do
  @moduledoc false
  # Guards Perplexed uses in function heads. Perplexed carries its own so it
  # depends on no host application.

  @doc "A non-empty binary."
  defguard is_present(value) when is_binary(value) and byte_size(value) > 0
end
