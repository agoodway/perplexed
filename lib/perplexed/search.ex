defmodule Perplexed.Search do
  @moduledoc """
  Swappable web search: every provider takes a query and returns normalized
  `Perplexed.Search.Hit`s, so callers change engines by changing one option.
  Built-in providers, by name, with list price per successful request (USD,
  as of 2026-11-10) used for per-run cost accounting:

  | Name              | Route                                | Per request |
  | ----------------- | ------------------------------------ | ----------- |
  | `:ceramic`        | Cloudflare Web Search, Ceramic       | $0.00025    |
  | `:deepseek`       | DeepSeek Search API                  | $0.00075    |
  | `:firecrawl`      | Firecrawl search, 2 Standard credits | $0.00198    |
  | `:linkup`         | Cloudflare Web Search, Linkup fast   | $0.005      |
  | `:cloudflare_exa` | Cloudflare Web Search, Exa auto      | $0.007      |
  | `:searxng`        | Your SearXNG instances, keyless      | free        |

  Firecrawl bills in credits, so its price follows the `firecrawl_credit_usd`
  setting (default the Standard plan rate).

  Any module implementing this behaviour can be passed instead, as `Module`
  or `{Module, opts}`; its optional `c:price/1` and `c:free_when_empty?/0`
  feed cost accounting.
  """

  alias Perplexed.{Adapter, Config, Telemetry}
  alias Perplexed.Search.{Cloudflare, DeepSeek, Fallback, Firecrawl, Hit, Result, SearXNG}

  @callback search(String.t(), keyword()) :: {:ok, [Hit.t()]} | {:error, term()}

  @doc """
  List price in USD of one successful request made with `opts` (the spec's
  options). Optional; defaults to 0.
  """
  @callback price(keyword()) :: float()

  @doc """
  Whether the provider does not bill a request that returns no hits.
  Optional; defaults to false, so an empty result costs the list price.
  """
  @callback free_when_empty?() :: boolean()

  @optional_callbacks price: 1, free_when_empty?: 0

  @builtin %{
    ceramic: {Cloudflare, [provider: "ceramic"]},
    linkup: {Cloudflare, [provider: "linkup"]},
    cloudflare_exa: {Cloudflare, [provider: "exa"]},
    deepseek: {DeepSeek, []},
    firecrawl: {Firecrawl, []},
    searxng: {SearXNG, []}
  }

  @default_provider :ceramic

  @type spec :: atom() | module() | {module(), keyword()} | [spec(), ...]

  @doc """
  The provider used when a call names none: `config :perplexed, provider:`,
  else `#{inspect(@default_provider)}`.
  """
  @spec default_provider() :: spec()
  def default_provider, do: Config.get(:provider, @default_provider)

  @doc """
  Searches `query` on `provider` and returns the hits with the call's cost.

  `:limit` (default 8) is common to the built-in providers; Cloudflare caps
  it at 10. `:credentials` (a keyword list of setting keys, such as
  `firecrawl_api_key:`) overrides the configured credentials for this call.
  `:req_options` is merged into each built-in provider's Req call last, so
  tests can pass `plug:`. Other options go to the provider.

  An unknown provider is `{:error, {:invalid_request, %{reason: {:unknown_provider, spec}}}}`.

  A list of specs is a fallback chain, tried in order until one answers,
  with per-provider and overall time limits (`:provider_timeout_ms`,
  `:deadline_ms`, `:fallback_on`); see `Perplexed.Search.Fallback`.
  """
  @spec run(spec(), String.t(), keyword()) :: {:ok, Result.t()} | {:error, Perplexed.error()}
  def run(provider, query, opts \\ [])

  def run([_ | _] = chain, query, opts) when is_list(opts), do: Fallback.run(chain, query, opts)

  def run(provider, query, opts) when is_list(opts) do
    with {:ok, {module, provider_opts}} <- resolve(provider) do
      Telemetry.span([:search], %{provider: name(provider), query: query}, fn ->
        query
        |> module.search(Keyword.merge(provider_opts, opts))
        |> searched(provider, query)
        |> span_stop()
      end)
    end
  end

  defp searched({:ok, hits}, provider, query) when is_list(hits) do
    cost = charge(hits, provider)

    {:ok,
     %Result{query: query, provider: name(provider), hits: hits, cost: cost, total_cost: cost}}
  end

  defp searched({:error, _reason} = error, _provider, _query), do: error

  defp charge([], provider), do: provider |> free_when_empty?() |> empty_price(provider)
  defp charge(_hits, provider), do: price(provider)

  defp empty_price(true, _provider), do: 0.0
  defp empty_price(false, provider), do: price(provider)

  defp free_when_empty?(provider), do: provider |> resolve() |> free_empty()

  defp free_empty({:ok, {module, _opts}}),
    do: Adapter.optional(module, :free_when_empty?, [], false)

  defp free_empty({:error, _reason}), do: false

  defp span_stop({:ok, %Result{hits: hits, cost: cost}} = result),
    do: {result, %{cost: cost, hits: length(hits)}, %{result: :ok}}

  defp span_stop({:error, _reason} = error), do: {error, %{cost: 0.0, hits: 0}, %{result: :error}}

  @doc """
  The name a provider is reported by in results, attempts and telemetry:
  a built-in name or the module, never a `{Module, opts}` spec's options,
  which can hold credentials. A fallback chain is `:chain`.
  """
  @spec name(spec()) :: atom()
  def name([_ | _]), do: :chain
  def name({module, opts}) when is_atom(module) and is_list(opts), do: module
  def name(name) when is_atom(name), do: name

  @doc """
  Price in USD of one successful request to `provider`: the
  `config :perplexed, prices:` override for that spec when set, else the
  provider's list price (0 for a provider without `c:price/1`).
  """
  @spec price(spec()) :: float()
  def price(provider), do: :prices |> Config.get(%{}) |> Map.fetch(provider) |> priced(provider)

  defp priced({:ok, price}, _provider), do: price * 1.0
  defp priced(:error, provider), do: provider |> resolve() |> list_price()

  defp list_price({:ok, {module, opts}}), do: Adapter.optional(module, :price, [opts], 0.0) * 1.0
  defp list_price({:error, _reason}), do: 0.0

  @doc "The built-in provider names."
  @spec providers() :: [atom()]
  def providers, do: Map.keys(@builtin)

  defp resolve(name) when is_map_key(@builtin, name), do: {:ok, Map.fetch!(@builtin, name)}

  defp resolve({module, opts} = spec) when is_atom(module) and is_list(opts),
    do: provider(module, opts, spec)

  defp resolve(module) when is_atom(module), do: provider(module, [], module)
  defp resolve(spec), do: unknown(spec)

  defp provider(module, opts, spec),
    do: module |> Adapter.exports?(:search, 2) |> provided({module, opts}, spec)

  defp provided(true, resolved, _spec), do: {:ok, resolved}
  defp provided(false, _resolved, spec), do: unknown(spec)

  defp unknown(spec), do: {:error, {:invalid_request, %{reason: {:unknown_provider, spec}}}}
end
