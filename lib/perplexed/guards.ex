defmodule Perplexed.Guards do
  @moduledoc false
  # Guards Perplexed uses in function heads. Perplexed carries its own so it
  # depends on no host application.

  @doc "A non-empty binary."
  defguard is_present(value) when is_binary(value) and byte_size(value) > 0

  @doc "`value` when it is a non-empty binary, else `nil` (blank or not text)."
  @spec presence(term()) :: String.t() | nil
  def presence(value) when is_present(value), do: value
  def presence(_blank), do: nil
end
