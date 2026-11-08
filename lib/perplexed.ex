defmodule Perplexed do
  @moduledoc """
  A small web search, scrape and research toolkit, in the spirit of Firecrawl
  or Exa.

    * `search/2` runs one web search on a chosen provider and returns a
      `Perplexed.Search.Result` with the hits and the call's cost. With
      `scrape: true` it also scrapes each hit's page and attaches the
      `Perplexed.Document`.
    * `scrape/2` turns one URL into Markdown through a configurable ladder
      of scrapers (see `Perplexed.Scrape`).
    * `batch_scrape/2` scrapes several URLs concurrently under
      `Perplexed.TaskSupervisor`.
    * `answer/2` answers a question from the web in fixed steps (plan,
      search, rank, scrape, summarize) and returns the answer with its sources
      and every hit considered (see `Perplexed.Pipeline`).

  Search providers and scrapers are adapters (`Perplexed.Search`,
  `Perplexed.Scraper`), so any of them can be swapped for another built-in
  or a custom module. Search and scrape need no model, so they work on their
  own as a search engine with optional page contents. Every result carries
  its USD cost.
  """

  alias Perplexed.{Document, Scrape, Search}
  alias Perplexed.Search.Result

  @typedoc """
  Every error Perplexed returns: a reason atom (such as `:invalid_request`,
  `:authentication`, `:quota_exhausted`, `:rate_limited`, `:upstream`,
  `:transport`, `:unreadable`) and a map of details.
  """
  @type error :: {atom(), map()}

  @typedoc "A ReqLLM model spec: `\"provider:model\"`, a tuple, or a model map or struct."
  @type model_spec :: String.t() | tuple() | map()

  @doc """
  Child spec that starts Perplexed with `settings` (see `Perplexed.Config`).
  Add `{Perplexed, settings}` to the host application's supervision tree;
  the settings are cleared when it stops. There is one instance per node.

  The settings are handed over inside a function, so supervisor and crash
  reports do not print the API keys they carry.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(settings) when is_list(settings),
    do: %{id: __MODULE__, start: {Perplexed.Settings, :start_link, [fn -> settings end]}}

  @doc """
  Searches the web for `query`.

  ## Options

    * `:provider` - a `t:Perplexed.Search.spec/0`, default
      `Perplexed.Search.default_provider/0`.
    * `:limit` - results to return, default 8 (Cloudflare caps it at 10).
    * `:scrape` - also scrape each hit's page, default `false`. A hit whose
      page could not be read keeps `document: nil` and says why in
      `scrape_error`.
    * `:scrape_options` - options for `batch_scrape/2`, such as `:ladder`.

  Other options go to the provider.
  """
  @spec search(String.t(), keyword()) :: {:ok, Result.t()} | {:error, error()}
  def search(query, opts \\ []) when is_list(opts) do
    {scrape?, opts} = Keyword.pop(opts, :scrape, false)
    {scrape_opts, opts} = Keyword.pop(opts, :scrape_options, [])
    {provider, opts} = Keyword.pop_lazy(opts, :provider, &Search.default_provider/0)

    with {:ok, %Result{} = result} <- Search.run(provider, query, opts) do
      {:ok, maybe_scrape(result, scrape?, scrape_opts)}
    end
  end

  @doc "Scrapes one URL to Markdown. Options are those of `Perplexed.Scrape.run/2`."
  @spec scrape(String.t(), keyword()) :: Scrape.result()
  defdelegate scrape(url, opts \\ []), to: Scrape, as: :run

  @doc "Scrapes URLs concurrently. See `Perplexed.Scrape.batch/2`."
  @spec batch_scrape([String.t()], keyword()) :: [{String.t(), Scrape.result()}]
  defdelegate batch_scrape(urls, opts \\ []), to: Scrape, as: :batch

  @doc """
  Answers `query` from the web in fixed steps (plan, search, rank, scrape,
  summarize) and returns the answer with its sources and every hit
  considered. See `Perplexed.Pipeline.run/2`.
  """
  @spec answer(String.t(), keyword()) :: {:ok, Perplexed.Answer.t()} | {:error, error()}
  defdelegate answer(query, opts \\ []), to: Perplexed.Pipeline, as: :run

  defp maybe_scrape(result, false, _scrape_opts), do: result

  defp maybe_scrape(%Result{hits: hits, cost: cost} = result, true, scrape_opts) do
    scraped =
      hits
      |> Enum.map(& &1.url)
      |> Enum.uniq()
      |> Scrape.batch(scrape_opts)
      |> Map.new()

    # Failed scrapes count too: a paid rung that answered is billed either way.
    scrape_cost = scraped |> Map.values() |> Enum.reduce(0.0, &(Scrape.cost(&1) + &2))

    %{
      result
      | hits: Enum.map(hits, &attach(&1, Map.fetch!(scraped, &1.url))),
        scrape_cost: scrape_cost,
        total_cost: cost + scrape_cost
    }
  end

  defp attach(hit, {:ok, %Document{} = document}), do: %{hit | document: document}
  defp attach(hit, {:error, reason}), do: %{hit | scrape_error: reason}
end
