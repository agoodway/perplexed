defmodule Perplexed.Scraper do
  @moduledoc """
  The behaviour of one scrape tier, and the registry of built-in tiers.

  A scraper turns one URL into a `Perplexed.Document` and, when it read HTML,
  the raw markup (so `Perplexed.Verdict` can spot challenge pages and
  JavaScript shells). Failures are plain outcome atoms such as `:blocked`,
  `:not_found` or `:timeout`.

  Built-in scrapers, referenced by name in a `Perplexed.Scrape` ladder:

  | Name            | Module                           |
  | --------------- | -------------------------------- |
  | `:direct`       | `Perplexed.Scraper.Direct`       |
  | `:impersonated` | `Perplexed.Scraper.Impersonated` |
  | `:browser_run`  | `Perplexed.Scraper.BrowserRun`   |
  | `:firecrawl`    | `Perplexed.Scraper.Firecrawl`    |
  | `:deepseek`     | `Perplexed.Scraper.DeepSeek`     |

  Any module implementing this behaviour can stand in a ladder too, as
  `Module` or `{Module, opts}`.
  """

  alias Perplexed.{Adapter, Clock, Document}
  alias Perplexed.Scraper.{BrowserRun, DeepSeek, Direct, Firecrawl, Impersonated}

  @type result :: {:ok, Document.t(), raw_html :: String.t() | nil} | {:error, atom()}
  @type spec :: atom() | module() | {module(), keyword()}
  @type rung :: {name :: atom(), module(), keyword()}

  @callback scrape(String.t(), keyword()) :: result()

  @doc """
  Whether this scraper is worth trying after an earlier tier failed with
  `outcome`. Optional; scrapers that leave it out are always tried.
  """
  @callback retries?(outcome :: atom()) :: boolean()

  @doc """
  USD cost of producing `document` with the rung's `opts`. Optional;
  defaults to 0 (free tiers).
  """
  @callback cost(Document.t(), keyword()) :: float()

  @doc """
  Whether the scraper can run with `opts` and the current settings, such as
  a paid one whose API key is set. Optional; defaults to true. The default
  ladder leaves out built-in rungs that are not configured.
  """
  @callback configured?(keyword()) :: boolean()

  @optional_callbacks retries?: 1, cost: 2, configured?: 1

  @builtin %{
    direct: Direct,
    impersonated: Impersonated,
    browser_run: BrowserRun,
    firecrawl: Firecrawl,
    deepseek: DeepSeek
  }

  @names Map.new(@builtin, fn {name, module} -> {module, name} end)

  @doc """
  Resolves a ladder entry to `{:ok, {name, module, opts}}`, or an
  `:invalid_request` error for anything that is not a built-in name or a
  module implementing `c:scrape/2`.
  """
  @spec resolve(spec()) :: {:ok, rung()} | {:error, {:invalid_request, map()}}
  def resolve(name) when is_map_key(@builtin, name),
    do: {:ok, {name, Map.fetch!(@builtin, name), []}}

  def resolve({module, opts} = spec) when is_atom(module) and is_list(opts),
    do: rung(module, opts, spec)

  def resolve(module) when is_atom(module), do: rung(module, [], module)
  def resolve(spec), do: unknown(spec)

  defp rung(module, opts, spec),
    do: module |> Adapter.exports?(:scrape, 2) |> resolved({name(module), module, opts}, spec)

  defp resolved(true, rung, _spec), do: {:ok, rung}
  defp resolved(false, _rung, spec), do: unknown(spec)

  defp unknown(spec), do: {:error, {:invalid_request, %{reason: {:unknown_scraper, spec}}}}

  @doc """
  Milliseconds a scraper may still spend: `default`, capped by the time left
  before the scrape's `:deadline` (a monotonic millisecond time that
  `Perplexed.Scrape.run/2` puts in the options). At least 1.
  """
  @spec time_left(keyword(), pos_integer()) :: pos_integer()
  def time_left(opts, default), do: time_left_until(Keyword.get(opts, :deadline), default)

  defp time_left_until(nil, default), do: default

  defp time_left_until(deadline, default),
    do: deadline |> Clock.left_ms() |> min(default) |> max(1)

  @doc """
  Whether the rung's scraper should be tried after an earlier tier failed
  with `outcome`. A scraper without `c:retries?/1` is tried after anything
  except `:unsupported` (a file type such as a PDF no earlier tier could
  convert), which only a scraper that says it reads such files is tried
  after.
  """
  @spec retries?(rung(), atom()) :: boolean()
  def retries?({_name, module, _opts}, outcome),
    do: Adapter.optional(module, :retries?, [outcome], outcome != :unsupported)

  @doc """
  Whether the rung's scraper can run with the call's `opts` (see
  `c:configured?/1`), such as per-call `credentials:`.
  """
  @spec configured?(rung(), keyword()) :: boolean()
  def configured?({_name, module, rung_opts}, opts \\ []),
    do: Adapter.optional(module, :configured?, [Keyword.merge(opts, rung_opts)], true)

  @doc "USD cost of `document` produced by the rung."
  @spec cost(rung(), Document.t()) :: float()
  def cost({_name, module, opts}, %Document{} = document),
    do: Adapter.optional(module, :cost, [document, opts], 0.0) * 1.0

  defp name(module), do: Map.get(@names, module, module)
end
