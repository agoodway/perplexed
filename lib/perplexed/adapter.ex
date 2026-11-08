defmodule Perplexed.Adapter do
  @moduledoc false
  # Resolution and optional-callback dispatch shared by the `Perplexed.Search`
  # and `Perplexed.Scraper` behaviours.

  @doc "Whether `module` is loaded and exports `fun/arity`."
  @spec exports?(module(), atom(), non_neg_integer()) :: boolean()
  def exports?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  @doc "Calls `module.fun(args...)` when exported, otherwise returns `default`."
  @spec optional(module(), atom(), list(), term()) :: term()
  def optional(module, fun, args, default),
    do: module |> exports?(fun, length(args)) |> call(module, fun, args, default)

  defp call(true, module, fun, args, _default), do: apply(module, fun, args)
  defp call(false, _module, _fun, _args, default), do: default
end
