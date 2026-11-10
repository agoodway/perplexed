defmodule Perplexed.Search.Fallback do
  @moduledoc """
  Opt-in provider fallback: a list of provider specs, tried in order until
  one answers, such as free first and paid last:

      Perplexed.search("zoning setbacks", provider: [:searxng, :ceramic, :firecrawl])

  `Perplexed.Search.run/3` comes here whenever the provider spec is a
  list, so the same list works in `Perplexed.search/2`, `Perplexed.answer/2`
  (its `:provider`) and the `provider` setting. A single provider behaves as
  it always has.

  A provider's answer moves the chain on when its outcome is in
  `:fallback_on`: `:error` (it failed or timed out) and `:empty` (it
  answered with no hits, often how a quiet block looks) by default. Each
  provider runs in a task under `Perplexed.TaskSupervisor` and gets
  `:provider_timeout_ms`, capped by what is left of the chain's
  `:deadline_ms`; one that overruns is shut down and counts as an error.
  Once the deadline passes, the providers left are recorded as `:deadline`
  and not called.

  The `Perplexed.Search.Result` names the provider that answered, carries
  every attempt in `attempts`, and costs what all of them cost (a paid
  provider that answered empty still bills). When every provider fails, an
  empty answer from one of them is still returned as the result; with no
  answer at all the chain is `{:error, {:upstream, %{reason:
  :all_providers_failed, attempts: attempts}}}`. Each provider's call still
  emits its own `[:perplexed, :search, ...]` span. Every attempt also
  emits `[:perplexed, :search, :attempt]` with `duration` (ms) and `cost`, and
  metadata `provider`, `outcome` and `billable`.
  """

  alias Perplexed.{Clock, Search, TaskSupervisor, Telemetry}
  alias Perplexed.Search.Result

  @provider_timeout_ms 15_000
  @deadline_ms 30_000
  @fallback_on [:error, :empty]
  @chain_options [:provider_timeout_ms, :deadline_ms, :fallback_on]

  @type outcome :: :ok | :empty | :timeout | :deadline | {:error, term()}
  @type attempt :: %{
          provider: Search.spec(),
          outcome: outcome(),
          cost: float(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Runs `query` down `chain`.

  ## Options

    * `:provider_timeout_ms` - each provider's limit, default #{@provider_timeout_ms}.
    * `:deadline_ms` - the whole chain's limit, default #{@deadline_ms}.
    * `:fallback_on` - outcomes that move on to the next provider, any of
      `:error` and `:empty`, default `#{inspect(@fallback_on)}`.

  Other options go to every provider.
  """
  @spec run([Search.spec(), ...], String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Perplexed.error()}
  def run([_ | _] = chain, query, opts) do
    {chain_opts, provider_opts} = Keyword.split(opts, @chain_options)

    context = %{
      query: query,
      opts: provider_opts,
      deadline: chain_opts |> Keyword.get(:deadline_ms, @deadline_ms) |> Clock.deadline(),
      provider_timeout_ms: Keyword.get(chain_opts, :provider_timeout_ms, @provider_timeout_ms),
      fallback_on: Keyword.get(chain_opts, :fallback_on, @fallback_on)
    }

    climb(chain, context, [], nil)
  end

  # `empty` keeps the first empty answer, returned if nothing better comes.
  defp climb([], _context, attempts, empty), do: exhausted(empty, attempts)

  defp climb([provider | rest], context, attempts, empty),
    do:
      provider
      |> attempt(context, Clock.left_ms(context.deadline))
      |> next(rest, context, attempts, empty)

  defp attempt(provider, _context, remaining_ms) when remaining_ms <= 0,
    do: {provider, :deadline, 0}

  # A closure, not an MFA: a crash report then cannot print `opts`, which can
  # carry credentials and proxy passwords.
  defp attempt(provider, %{query: query, opts: opts} = context, remaining_ms) do
    {reply, ms} =
      Clock.timed(fn ->
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn -> Search.run(provider, query, opts) end)

        Task.yield(task, min(context.provider_timeout_ms, remaining_ms)) ||
          Task.shutdown(task, :brutal_kill)
      end)

    {provider, answered(reply), ms}
  end

  defp answered({:ok, {:ok, %Result{hits: []} = result}}), do: {:empty, result}
  defp answered({:ok, {:ok, %Result{} = result}}), do: {:ok, result}
  defp answered({:ok, {:error, reason}}), do: {:error, reason}
  defp answered({:exit, reason}), do: {:error, {:exit, %{reason: exit_reason(reason)}}}
  defp answered(nil), do: :timeout

  # What crashed, without the stacktrace or arguments a raw exit carries.
  defp exit_reason({%{__exception__: true, __struct__: exception}, _stacktrace}), do: exception
  defp exit_reason({reason, _stacktrace}) when is_atom(reason), do: reason
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_other), do: :crashed

  # The chain stops at a good answer, or at an outcome it was told not to
  # move past.
  defp next({provider, {:ok, result}, ms}, _rest, _context, attempts, _empty),
    do: finished(result, [record(provider, :ok, result, ms) | attempts])

  defp next({provider, {:empty, result}, ms}, rest, context, attempts, empty) do
    attempts = [record(provider, :empty, result, ms) | attempts]
    empty = empty || result
    continue(:empty in context.fallback_on, rest, context, attempts, empty, {:empty, empty})
  end

  defp next({provider, :deadline, ms}, rest, context, attempts, empty),
    do: climb(rest, context, [record(provider, :deadline, nil, ms) | attempts], empty)

  defp next({provider, failure, ms}, rest, context, attempts, empty) do
    attempts = [record(provider, outcome(failure), nil, ms) | attempts]
    continue(:error in context.fallback_on, rest, context, attempts, empty, failure)
  end

  # `stop` is what the chain returns if it may not fall back past this outcome.
  defp continue(true = _fall_back, rest, context, attempts, empty, _stop),
    do: climb(rest, context, attempts, empty)

  defp continue(false = _fall_back, _rest, _context, attempts, _empty, {:empty, result}),
    do: finished(result, attempts)

  defp continue(false = _fall_back, _rest, _context, attempts, _empty, failure),
    do: failed(failure, Enum.reverse(attempts))

  defp outcome(:timeout), do: :timeout
  defp outcome({:error, reason}), do: {:error, reason}

  # Each attempt is also reported as it happens, so spend and success per
  # provider can be tracked without the result. Only the provider's name is
  # recorded: a `{Module, opts}` spec's options can hold credentials.
  defp record(provider, outcome, result, ms) do
    name = Search.name(provider)
    attempt = %{provider: name, outcome: outcome, cost: cost(result), duration_ms: ms}
    Telemetry.attempt(:search, ms, attempt.cost, %{provider: name, outcome: outcome})
    attempt
  end

  defp cost(%Result{cost: cost}), do: cost
  defp cost(nil), do: 0.0

  defp finished(%Result{} = result, attempts) do
    attempts = Enum.reverse(attempts)
    cost = attempts |> Enum.map(& &1.cost) |> Enum.sum()
    {:ok, %{result | attempts: attempts, cost: cost, total_cost: cost + result.scrape_cost}}
  end

  defp exhausted(%Result{} = empty, attempts), do: finished(empty, attempts)

  defp exhausted(nil, attempts),
    do: {:error, {:upstream, %{reason: :all_providers_failed, attempts: Enum.reverse(attempts)}}}

  defp failed(:timeout, attempts), do: {:error, {:timeout, %{attempts: attempts}}}

  defp failed({:error, {reason, details}}, attempts) when is_atom(reason) and is_map(details),
    do: {:error, {reason, Map.put(details, :attempts, attempts)}}

  defp failed({:error, reason}, attempts),
    do: {:error, {:upstream, %{reason: reason, attempts: attempts}}}
end
