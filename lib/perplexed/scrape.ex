defmodule Perplexed.Scrape do
  @moduledoc """
  Scrapes a URL to Markdown by climbing a ladder of `Perplexed.Scraper`s,
  cheapest first.

  The default ladder is `[:direct, :impersonated, :firecrawl]`: plain HTTP,
  then a browser TLS fingerprint, both free, then Firecrawl's hosted scraper,
  which renders JavaScript and gets past most bot challenges. Swap any rung
  for another scraper, for example `[:direct, :impersonated, :browser_run]`,
  or for your own module implementing `Perplexed.Scraper`.

  The URL is checked by `Perplexed.UrlGuard` once, before any rung, so a
  private address never reaches a hosted scraper either. Each rung's text is
  judged by `Perplexed.Verdict`. After a failure the climb skips rungs whose
  `c:Perplexed.Scraper.retries?/1` says they cannot help with that outcome;
  impersonation, for one, does nothing for a JavaScript shell. A missing
  page, a redirect into a private network, a scanned PDF needing OCR, an
  encrypted PDF, an unsupported file type or an oversized body ends the climb.

  A scrape has one deadline (`:timeout`). Each rung gets only the time left,
  and once it has passed the next rung is recorded as `:deadline` and the
  climb stops. Every rung's cost counts, including a paid rung whose page
  then failed the readability check.
  """

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Document, Scraper, Telemetry, UrlGuard, Verdict}

  @default_ladder [:direct, :impersonated, :firecrawl]
  # Outcomes no later rung can fix.
  @terminal_outcomes [
    :not_found,
    :needs_ocr,
    :encrypted,
    :unsupported,
    :too_large,
    :private_address,
    :invalid_url,
    :unresolvable_host
  ]
  @timeout_ms 60_000
  # Extra time a batch task gets past its scrape deadline before it is killed.
  @batch_grace_ms 1_000
  @batch_concurrency 6

  @type attempts :: [{atom(), atom()}]
  @type result ::
          {:ok, Document.t()}
          | {:error, {:unreadable, %{attempts: attempts(), cost: float()}}}
          | {:error, Perplexed.error()}

  @doc """
  Scrapes `url`, returning the first rung's readable `Perplexed.Document`.

  When every rung fails, answers
  `{:error, {:unreadable, %{attempts: attempts, cost: cost}}}`, where
  `attempts` lists each rung tried with its outcome and `cost` is what those
  rungs cost. A blank URL, one the URL guard refuses, or an unknown ladder
  entry is `{:error, {:invalid_request, %{reason: reason, ...}}}`.

  ## Options

    * `:ladder` - the `t:Perplexed.Scraper.spec/0` entries to try, in order,
      default `default_ladder/0`.
    * `:timeout` - the whole scrape's deadline in milliseconds, default
      #{@timeout_ms}.
    * `:url_validator` - a `{Module, :fun, args}` URL check for this call,
      overriding the configured one (see `Perplexed.UrlGuard`).

  Other options go to every scraper; per-scraper options ride on a
  `{Module, opts}` ladder entry.
  """
  @spec run(String.t(), keyword()) :: result()
  def run(url, opts \\ [])

  def run(url, opts) when is_present(url) and is_list(opts) do
    {ladder, opts} = Keyword.pop_lazy(opts, :ladder, &default_ladder/0)
    {timeout, opts} = Keyword.pop(opts, :timeout, @timeout_ms)

    with {:ok, url} <- url |> UrlGuard.check(opts) |> guarded(url),
         {:ok, rungs} <- rungs(ladder) do
      opts = Keyword.put(opts, :deadline, System.monotonic_time(:millisecond) + timeout)

      Telemetry.span([:scrape], %{url: url}, fn ->
        url |> climb(rungs, {[], 0.0}, opts) |> span_stop()
      end)
    end
  end

  def run(url, _opts), do: {:error, {:invalid_request, %{reason: :invalid_url, url: url}}}

  @doc """
  Scrapes `urls` concurrently and returns `{url, result}` pairs in input order.

  Each scrape runs in an unlinked task under `Perplexed.TaskSupervisor`, with
  bounded concurrency and a per-URL timeout that kills the task, so a crash
  or a hang becomes that URL's `{:error, {:exit, %{reason: reason}}}` instead
  of taking the caller down.

  ## Options

    * `:max_concurrency` - default #{@batch_concurrency}.
    * `:timeout` - each URL's scrape deadline (see `run/2`); the task is
      killed #{@batch_grace_ms} ms after it.
    * `:task_supervisor` - default `Perplexed.TaskSupervisor`.

  Other options go to `run/2`.
  """
  @spec batch([String.t()], keyword()) :: [{String.t(), result()}]
  def batch(urls, opts \\ []) when is_list(urls) and is_list(opts) do
    {supervisor, opts} = Keyword.pop(opts, :task_supervisor, Perplexed.TaskSupervisor)
    {max_concurrency, opts} = Keyword.pop(opts, :max_concurrency, @batch_concurrency)
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    supervisor
    |> Task.Supervisor.async_stream_nolink(urls, &run(&1, opts),
      max_concurrency: max_concurrency,
      timeout: timeout + @batch_grace_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip_with(urls, &batch_result(&2, &1))
  end

  @doc """
  The ladder `run/2` uses when none is given: `config :perplexed, ladder:`,
  else `#{inspect(@default_ladder)}`.
  """
  @spec default_ladder() :: [Scraper.spec()]
  def default_ladder, do: Config.get(:ladder, @default_ladder)

  @doc "USD cost of a scrape result, whether it succeeded or every rung failed."
  @spec cost(result()) :: float()
  def cost({:ok, %Document{cost: cost}}), do: cost
  def cost({:error, {:unreadable, %{cost: cost}}}), do: cost
  def cost(_other), do: 0.0

  defp guarded({:ok, url}, _url), do: {:ok, url}

  defp guarded({:error, reason}, url),
    do: {:error, {:invalid_request, %{reason: reason, url: url}}}

  defp rungs(ladder), do: ladder |> Enum.reduce_while({:ok, []}, &add_rung/2) |> in_order()

  defp add_rung(spec, {:ok, rungs}), do: spec |> Scraper.resolve() |> collect(rungs)

  defp collect({:ok, rung}, rungs), do: {:cont, {:ok, [rung | rungs]}}
  defp collect({:error, _reason} = error, _rungs), do: {:halt, error}

  defp in_order({:ok, rungs}), do: {:ok, Enum.reverse(rungs)}
  defp in_order(error), do: error

  defp span_stop({:ok, %Document{} = document} = result) do
    {result, %{cost: document.cost, browser_ms: document.browser_ms},
     %{tier: document.tier, attempts: document.attempts, result: :ok}}
  end

  defp span_stop({:error, {:unreadable, %{attempts: attempts, cost: cost}}} = result),
    do: {result, %{cost: cost, browser_ms: 0}, %{tier: nil, attempts: attempts, result: :error}}

  defp batch_result(url, {:ok, result}), do: {url, result}
  defp batch_result(url, {:exit, reason}), do: {url, {:error, {:exit, %{reason: reason}}}}

  defp climb(_url, [], {attempts, spent}, _opts), do: unreadable(attempts, spent)

  defp climb(url, [rung | rest], acc, opts), do: step(past?(opts), url, rung, rest, acc, opts)

  # `past?/1` first: once the deadline has passed, the next rung is
  # recorded as `:deadline` and the climb ends.
  defp step(true, _url, {name, _, _}, _rest, {attempts, spent}, _opts),
    do: unreadable([{name, :deadline} | attempts], spent)

  defp step(false, url, rung, rest, acc, opts),
    do: rung |> attempt(url, opts) |> climbed(url, rung, rest, acc, opts)

  defp climbed(
         {:ok, %Document{} = document, cost},
         url,
         {name, _, _},
         _rest,
         {attempts, spent},
         _opts
       ) do
    {:ok,
     %{
       document
       | url: url,
         tier: name,
         attempts: Enum.reverse([{name, :ok} | attempts]),
         cost: spent + cost
     }}
  end

  defp climbed({:error, outcome, cost}, url, {name, _, _}, rest, {attempts, spent}, opts),
    do: climb(url, escalate(rest, outcome), {[{name, outcome} | attempts], spent + cost}, opts)

  defp past?(opts), do: System.monotonic_time(:millisecond) >= Keyword.fetch!(opts, :deadline)

  defp unreadable(attempts, spent),
    do: {:error, {:unreadable, %{attempts: Enum.reverse(attempts), cost: spent * 1.0}}}

  # `{:ok, document, cost}` or `{:error, outcome, cost}`: a rung that answered
  # costs what its scraper charges even when the page then fails the check.
  defp attempt({_name, module, scraper_opts} = rung, url, opts),
    do: url |> module.scrape(Keyword.merge(opts, scraper_opts)) |> scraped(rung)

  defp scraped({:ok, %Document{markdown: markdown} = document, raw}, rung),
    do: markdown |> Verdict.judge(raw) |> judged(document, Scraper.cost(rung, document))

  defp scraped({:error, outcome}, _rung), do: {:error, outcome, 0.0}

  defp judged(:ok, document, cost), do: {:ok, document, cost}
  defp judged(verdict, _document, cost), do: {:error, verdict, cost}

  defp escalate(_rest, outcome) when outcome in @terminal_outcomes, do: []
  defp escalate(rest, outcome), do: Enum.drop_while(rest, &(not Scraper.retries?(&1, outcome)))
end
