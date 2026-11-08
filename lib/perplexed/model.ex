defmodule Perplexed.Model do
  @moduledoc false
  # The ReqLLM model behind `Perplexed.answer/2`: resolving the model spec,
  # parsing structured output against a Zoi schema, and recording each call's
  # tokens and cost.

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Telemetry}
  alias ReqLLM.Response

  @token_keys [:input_tokens, :output_tokens, :reasoning_tokens, :total_tokens]

  @type spec :: Perplexed.model_spec()

  @doc "The model spec from `opts[:model]`, else `config :perplexed, model:`."
  @spec fetch(keyword()) :: {:ok, spec()} | {:error, {:invalid_request, map()}}
  def fetch(opts), do: opts |> Keyword.get_lazy(:model, fn -> Config.get(:model) end) |> spec()

  defp spec(model) when is_present(model) or is_tuple(model) or is_map(model), do: {:ok, model}
  defp spec(_unset), do: {:error, {:invalid_request, %{reason: :no_model}}}

  @doc """
  Parses a model's JSON `object` against `schema`, returning a string-keyed map.

  Model JSON arrives with string keys; object schemas are made to coerce
  them, so atom-keyed caller schemas still parse.
  """
  @spec parse(term(), Zoi.schema()) :: {:ok, map()} | :error
  def parse(object, schema), do: schema |> string_keyed() |> Zoi.parse(object) |> parsed()

  defp parsed({:ok, parsed}), do: {:ok, stringify(parsed)}
  defp parsed({:error, _errors}), do: :error

  @doc """
  A trace entry for one model call in `phase`, with its tokens and cost, and
  the matching `[:perplexed, :model]` telemetry event. `extra` is merged in.
  """
  @spec entry(Response.t(), spec(), atom(), map()) :: map()
  def entry(%Response{} = response, model, phase, extra \\ %{}) do
    usage = Response.usage(response) || %{}
    tokens = Map.take(usage, @token_keys)

    Telemetry.emit([:model], Map.put(tokens, :cost, usage[:total_cost]), %{
      model: model,
      phase: phase
    })

    tokens
    |> Map.merge(%{kind: :model, phase: phase, cost: usage[:total_cost]})
    |> Map.merge(extra)
  end

  @doc """
  Usage totals for a trace: token counts, call counts, scrape tiers, and USD
  cost by kind. `model_cost` and `total_cost` are `nil` when any model
  call's price is unknown; search and scrape cost are still reported.
  """
  @spec usage([map()]) :: map()
  def usage(trace) when is_list(trace) do
    by_kind = Enum.group_by(trace, & &1.kind)
    model_calls = Map.get(by_kind, :model, [])
    searches = Map.get(by_kind, :search, [])
    scrapes = Map.get(by_kind, :scrape, [])
    model_cost = known_sum(model_calls)
    search_cost = known_sum(searches)
    scrape_cost = known_sum(scrapes)

    tokens =
      Map.new(@token_keys, fn key ->
        {key, model_calls |> Enum.map(&(&1[key] || 0)) |> Enum.sum()}
      end)

    Map.merge(tokens, %{
      model_calls: length(model_calls),
      searches: length(searches),
      scrapes: length(scrapes),
      scrape_tiers: scrapes |> Enum.map(&(&1[:tier] || :failed)) |> Enum.frequencies(),
      model_cost: model_cost,
      search_cost: search_cost,
      scrape_cost: scrape_cost,
      total_cost: total(model_cost, search_cost + scrape_cost)
    })
  end

  defp total(nil, _known), do: nil
  defp total(model_cost, known), do: model_cost + known

  # Sum of entry costs, or nil when any entry's cost is unknown.
  defp known_sum(entries), do: Enum.reduce_while(entries, 0.0, &add_cost/2)

  defp add_cost(%{cost: nil}, _sum), do: {:halt, nil}
  defp add_cost(%{cost: cost}, sum), do: {:cont, sum + cost}

  defp string_keyed(schema), do: schema |> Zoi.Schema.traverse(&coerce/1) |> coerce()

  defp coerce(%Zoi.Types.Map{fields: fields} = object) when is_list(fields),
    do: %{object | coerce: true}

  defp coerce(schema), do: schema

  defp stringify(%_struct{} = struct), do: struct

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
