defmodule Perplexed.Scrape do
  @moduledoc """
  Scrapes a URL to Markdown by climbing a ladder of `Perplexed.Scraper`s,
  cheapest first.

  The default ladder is `[:direct, :impersonated, :deepseek, :firecrawl]`:
  plain HTTP, then a browser TLS fingerprint, both free, then the hosted
  scrapers cheapest first, DeepSeek Fetch and then Firecrawl, which renders
  JavaScript and gets past most bot challenges. A hosted rung is left out
  when its key is not set, so with no keys the default is the two free
  rungs. Swap any rung for another scraper, for example
  `[:direct, :impersonated, :browser_run]`, or for your own module
  implementing `Perplexed.Scraper`.

  The URL is checked by `Perplexed.UrlGuard` once, before any rung, so a
  private address never reaches a hosted scraper either. Each rung's text is
  judged by `Perplexed.Verdict`. After a failure the climb skips rungs whose
  `c:Perplexed.Scraper.retries?/1` says they cannot help with that outcome;
  impersonation, for one, does nothing for a JavaScript shell. A missing
  page, a redirect into a private network, a scanned PDF needing OCR, an
  encrypted PDF or an oversized body ends the climb. A file type no earlier
  rung could convert (`:unsupported`, such as a PDF with no
  `Perplexed.PdfConverter` configured) goes on only to rungs that read such
  files, which for Firecrawl means `firecrawl_pdf: true`.

  A scrape has one deadline (`:timeout`). Each rung gets only the time left,
  and once it has passed the next rung is recorded as `:deadline` and the
  climb stops. Every rung's cost counts, including a paid rung whose page
  then failed the readability check.
  """

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Clock, Config, Document, Scraper, TaskSupervisor, Telemetry, UrlGuard, Verdict}

  # Cheapest first: the free tiers, then each paid one whose key is set.
  @default_ladder [:direct, :impersonated, :deepseek, :firecrawl]
  # Outcomes no later rung can fix. (`:unsupported` goes on only to rungs
  # that read such files; see `Scraper.retries?/2`.)
  @terminal_outcomes [
    :not_found,
    :needs_ocr,
    :encrypted,
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
    {ladder, opts} = Keyword.pop_lazy(opts, :ladder, fn -> default_ladder(opts) end)
    {timeout, opts} = Keyword.pop(opts, :timeout, @timeout_ms)

    with {:ok, url} <- url |> UrlGuard.check(opts) |> guarded(url),
         {:ok, rungs} <- rungs(ladder) do
      opts = Keyword.put(opts, :deadline, Clock.deadline(timeout))

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
    {supervisor, opts} = Keyword.pop(opts, :task_supervisor, TaskSupervisor)
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
  else `#{inspect(@default_ladder)}`, cheapest first, without the paid
  rungs whose keys are not set in the settings or in `opts[:credentials]`
  (so with no keys it is the two free ones).
  """
  @spec default_ladder(keyword()) :: [Scraper.spec()]
  def default_ladder(opts \\ []),
    do: Config.get(:ladder) || Enum.filter(@default_ladder, &configured?(&1, opts))

  defp configured?(name, opts), do: name |> Scraper.resolve() |> resolved_configured?(opts)

  defp resolved_configured?({:ok, rung}, opts), do: Scraper.configured?(rung, opts)
  defp resolved_configured?({:error, _unknown}, _opts), do: false

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

  defp past?(opts), do: opts |> Keyword.fetch!(:deadline) |> Clock.past?()

  defp unreadable(attempts, spent),
    do: {:error, {:unreadable, %{attempts: Enum.reverse(attempts), cost: spent * 1.0}}}

  # `{:ok, document, cost}` or `{:error, outcome, cost}`: a rung that answered
  # costs what its scraper charges even when the page then fails the check.
  defp attempt({name, module, scraper_opts} = rung, url, opts) do
    {attempted, ms} =
      Clock.timed(fn ->
        url |> module.scrape(Keyword.merge(opts, scraper_opts)) |> scraped(rung)
      end)

    emit_attempt(attempted, url, name, ms)
    attempted
  end

  defp emit_attempt(attempted, url, tier, duration),
    do:
      Telemetry.attempt(:scrape, duration, attempt_cost(attempted), %{
        url: url,
        tier: tier,
        outcome: attempt_outcome(attempted)
      })

  defp attempt_cost({_status, _document_or_outcome, cost}), do: cost

  defp attempt_outcome({:ok, _document, _cost}), do: :ok
  defp attempt_outcome({:error, outcome, _cost}), do: outcome

  defp scraped({:ok, %Document{markdown: markdown} = document, raw}, rung),
    do: markdown |> Verdict.judge(raw) |> judged(document, Scraper.cost(rung, document))

  defp scraped({:error, outcome}, _rung), do: {:error, outcome, 0.0}

  defp judged(:ok, document, cost), do: {:ok, document, cost}
  defp judged(verdict, _document, cost), do: {:error, verdict, cost}

  defp escalate(_rest, outcome) when outcome in @terminal_outcomes, do: []
  defp escalate(rest, outcome), do: Enum.drop_while(rest, &(not Scraper.retries?(&1, outcome)))
end
