defmodule Perplexed.Search.SearXNG.Pool do
  @moduledoc """
  Health, speed and rate-limit state for SearXNG instances, learned from the
  searches this node makes. One pool runs under the `:perplexed` application;
  tests and hosts can start more with `:name`.

  ## Ranking

  Each instance keeps exponentially weighted moving averages (EWMA) of its
  response time and failure rate, and is scored

      latency_ewma_ms * (1 + failure_penalty * failure_ewma) * jitter

  lowest first. An instance not measured yet scores its prior: the
  searx.space median when it was `seed/2`ed, else `:prior_ms`. `:jitter`
  multiplies each score by a random factor in `1 +/- jitter`, so the
  fastest few share the load instead of one taking every search.
  `:min_interval_ms` ranks an instance used that recently after every
  rested one, least recently used first.

  ## Circuit breaker

  Each instance is a small state machine:

      :closed --refusal--> :open --cooldown timer--> :half_open
         ^                   ^                          |
         |                   +--------trial fails-------+
         +------------------------trial answers---------+

  A refusal (HTTP 429 or 503, a redirect from SearXNG's limiter, 403/418, a
  bot challenge, a timeout, a transport error) opens the circuit. The
  cooldown is the server's own `Retry-After` / `RateLimit-Reset` when it
  sent one, otherwise `:cooldown_ms` doubled per consecutive refusal, capped
  at `:max_cooldown_ms` either way. When it ends a timer moves the instance
  to `:half_open`, where it hands out a single trial lease: an answer closes
  the circuit, a refusal opens it again for twice as long. An open instance
  is never checked out. An empty or off-topic answer is a soft failure: the
  instance is reachable, so the circuit closes, but its failure average
  rises, and `:soft_strikes` (default 3) in a row open the circuit like a
  refusal: an instance that keeps answering off-topic is skipped for a
  while however fast it is.

  ## Leases

  `checkout/3` picks and reserves instances in one step inside the server,
  so concurrent searches spread out instead of racing onto the same
  instance. The pool monitors the caller; if it dies, its leases are
  released. `record/4` reports the outcome and returns the lease.

  Rankings and stats are read straight from ETS, so inspection never waits
  on the process. Instances idle longer than `:forget_after_ms` are swept
  out.

  Every state change emits `[:perplexed, :searxng, :circuit]` with metadata
  `instance`, `from`, `to` and `cooldown_ms`.
  """

  use GenServer

  alias Perplexed.{Clock, Telemetry}
  alias Perplexed.Search.SearXNG.Server

  @alpha 0.3
  @prior_ms 2_500
  @failure_penalty 3.0
  @cooldown_ms 60_000
  @max_cooldown_ms 30 * 60_000
  @forget_after_ms 6 * 60 * 60_000
  @sweep_every_ms 10 * 60_000
  @soft_strikes 3
  @hard_failures [
    :blocked,
    :unsafe_url,
    :challenge,
    :rate_limited,
    :unavailable,
    :timeout,
    :transport,
    :http_error
  ]

  @type circuit :: :closed | :open | :half_open
  @type outcome ::
          {:ok, non_neg_integer()} | {:error, atom()} | {:error, atom(), non_neg_integer() | nil}
  @type lease :: {String.t(), reference()}

  @type stats :: %{
          circuit: circuit(),
          latency_ms: float() | nil,
          failure_rate: float(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          consecutive_failures: non_neg_integer(),
          consecutive_soft: non_neg_integer(),
          cooldown_until: integer() | nil,
          in_flight: non_neg_integer(),
          last_outcome: atom() | nil,
          last_used_at: integer() | nil,
          prior_ms: number() | nil,
          seeded_at: integer() | nil
        }

  # --- Public API ---

  @doc """
  Starts a pool.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:cooldown_ms`
  (default #{@cooldown_ms}), `:max_cooldown_ms` (default #{@max_cooldown_ms}),
  `:forget_after_ms` (default #{@forget_after_ms}) and `:sweep_every_ms`
  (default #{@sweep_every_ms}) and `:soft_strikes` (default #{@soft_strikes}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Server.start_link(__MODULE__, opts)

  @doc """
  Reserves up to `count` of `candidates`, best first, skipping open
  circuits and half-open ones whose trial is already out. Returns the
  leases to pass to `record/4`.

  Options: `:pool`, `:jitter` (0 to 1, default 0), `:min_interval_ms`
  (default 0), `:prior_ms` (default #{@prior_ms}), `:failure_penalty`
  (default #{@failure_penalty}) and `:random` (a zero-arity function
  returning a float in [0, 1), for tests).
  """
  @spec checkout([String.t()], non_neg_integer(), keyword()) :: [lease()]
  def checkout(candidates, count, opts \\ []),
    do: GenServer.call(pool(opts), {:checkout, candidates, count, opts})

  @doc """
  Reports how a leased search went and releases the lease. `outcome` is
  `{:ok, hits}`, `{:error, reason}`, or `{:error, reason, retry_after_ms}`
  when the instance said how long to wait.
  """
  @spec record(lease(), outcome(), non_neg_integer(), keyword()) :: :ok
  def record(lease, outcome, elapsed_ms, opts \\ []),
    do: GenServer.call(pool(opts), {:record, lease, outcome, elapsed_ms})

  @doc """
  The instances in `candidates` that `checkout/3` would hand out, best
  first, without reserving them. Takes `checkout/3`'s options.
  """
  @spec rank([String.t()], keyword()) :: [String.t()]
  def rank(candidates, opts \\ []), do: ranked(table(pool(opts)), candidates, now(), opts)

  @doc """
  Sets prior response times (ms) for instances not measured yet, such as
  searx.space medians from `Perplexed.Search.SearXNG.Directory`.
  """
  @spec seed([{String.t(), number()}], keyword()) :: :ok
  def seed(priors, opts \\ []), do: GenServer.call(pool(opts), {:seed, priors})

  @doc "The stats for `instance` (fresh ones when it has none yet)."
  @spec stats(String.t(), GenServer.name()) :: stats()
  def stats(instance, pool \\ __MODULE__), do: lookup(table(pool), instance)

  @doc "Every instance the pool knows, with its stats, best first."
  @spec snapshot(keyword()) :: [{String.t(), stats()}]
  def snapshot(opts \\ []) do
    opts
    |> pool()
    |> table()
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_url, stats} -> {circuit_order(stats.circuit), score(stats, opts)} end)
  end

  @doc "Forgets everything the pool learned and cancels its timers."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []), do: GenServer.call(pool(opts), :reset)

  # --- Callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = Server.open_table(__MODULE__, name)

    state = %{
      name: name,
      table: table,
      leases: %{},
      timers: %{},
      cooldown_ms: Keyword.get(opts, :cooldown_ms, @cooldown_ms),
      max_cooldown_ms: Keyword.get(opts, :max_cooldown_ms, @max_cooldown_ms),
      forget_after_ms: Keyword.get(opts, :forget_after_ms, @forget_after_ms),
      sweep_every_ms: Keyword.get(opts, :sweep_every_ms, @sweep_every_ms),
      soft_strikes: Keyword.get(opts, :soft_strikes, @soft_strikes)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, candidates, count, opts}, {caller, _tag}, state) do
    now = now()
    picked = state.table |> ranked(candidates, now, opts) |> Enum.take(count)

    {leases, state} =
      Enum.map_reduce(picked, state, fn instance, state ->
        ref = Process.monitor(caller)
        update_stats(state, instance, &%{&1 | in_flight: &1.in_flight + 1, last_used_at: now})
        {{instance, ref}, put_in(state.leases[ref], instance)}
      end)

    {:reply, leases, state}
  end

  # A lease is recorded once: a second report for it (a task that recorded
  # and was then killed for overrunning) is ignored.
  def handle_call({:record, {instance, ref}, outcome, elapsed_ms}, _from, state),
    do:
      {:reply, :ok,
       state |> pop_lease(ref) |> recorded(state, {instance, ref}, outcome, elapsed_ms)}

  def handle_call({:seed, priors}, _from, state) do
    Enum.each(priors, fn {instance, prior} ->
      update_stats(state, instance, &%{&1 | prior_ms: prior, seeded_at: now()})
    end)

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.timers, fn {_instance, {timer, _generation}} ->
      Process.cancel_timer(timer)
    end)

    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | timers: %{}}}
  end

  # A cooldown ended. The generation guards against a timer that a later
  # transition already replaced.
  @impl true
  def handle_info({:half_open, instance, generation}, state),
    do: {:noreply, half_open(state, instance, generation, Map.get(state.timers, instance))}

  # A caller died holding leases: give them back without a sample.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, state |> pop_lease(ref) |> returned(state)}

  def handle_info(:sweep, state) do
    cutoff = now() - state.forget_after_ms

    for {instance, stats} <- :ets.tab2list(state.table), forgettable?(stats, cutoff) do
      :ets.delete(state.table, instance)
    end

    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info(_stray, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Server.close_table(__MODULE__, state.name)

  # Idle past the cutoff with nothing out: no lease, no cooldown running.
  # A seeded instance that was never used counts from when it was seeded.
  defp forgettable?(%{in_flight: 0, circuit: circuit} = stats, cutoff)
       when circuit in [:closed, :half_open],
       do: last_seen(stats) <= cutoff

  defp forgettable?(_busy_or_open, _cutoff), do: false

  defp last_seen(%{last_used_at: used}) when is_integer(used), do: used
  defp last_seen(%{seeded_at: seeded}) when is_integer(seeded), do: seeded
  defp last_seen(_never), do: 0

  # --- Ranking ---

  defp ranked(table, candidates, now, opts) do
    rested_after = now - Keyword.get(opts, :min_interval_ms, 0)

    {rested, busy} =
      candidates
      |> Enum.uniq()
      |> Enum.map(&{&1, lookup(table, &1)})
      |> Enum.filter(fn {_url, stats} -> available?(stats) end)
      |> Enum.split_with(fn {_url, stats} -> rested?(stats, rested_after) end)

    urls(Enum.sort_by(rested, fn {_url, stats} -> score(stats, opts) * jitter(opts) end)) ++
      urls(Enum.sort_by(busy, fn {_url, stats} -> stats.last_used_at end))
  end

  defp available?(%{circuit: :closed}), do: true
  defp available?(%{circuit: :half_open, in_flight: 0}), do: true
  defp available?(_open_or_trial_out), do: false

  defp rested?(%{last_used_at: nil}, _rested_after), do: true
  defp rested?(%{last_used_at: used}, rested_after), do: used <= rested_after

  defp score(stats, opts) do
    latency = stats.latency_ms || stats.prior_ms || Keyword.get(opts, :prior_ms, @prior_ms)
    latency * (1 + Keyword.get(opts, :failure_penalty, @failure_penalty) * stats.failure_rate)
  end

  defp jitter(opts), do: opts |> Keyword.get(:jitter, 0) |> jitter(opts)

  defp jitter(amount, opts) when amount > 0,
    do: 1 + amount * (2 * Keyword.get(opts, :random, &:rand.uniform/0).() - 1)

  defp jitter(_none, _opts), do: 1.0

  defp urls(entries), do: Enum.map(entries, &elem(&1, 0))

  defp circuit_order(:closed), do: 0
  defp circuit_order(:half_open), do: 1
  defp circuit_order(:open), do: 2

  # --- Transitions ---

  defp settle(state, instance, {:ok, _hits}, elapsed_ms) do
    stats = lookup(state.table, instance)

    put_stats(state, instance, %{
      stats
      | circuit: :closed,
        latency_ms: ewma(stats.latency_ms, elapsed_ms),
        failure_rate: (1 - @alpha) * stats.failure_rate,
        successes: stats.successes + 1,
        consecutive_failures: 0,
        consecutive_soft: 0,
        cooldown_until: nil,
        last_outcome: :ok
    })

    closed(state, instance, stats.circuit)
  end

  defp settle(state, instance, {:error, reason}, elapsed_ms),
    do: settle(state, instance, {:error, reason, nil}, elapsed_ms)

  defp settle(state, instance, {:error, reason, retry_after_ms}, elapsed_ms)
       when reason in @hard_failures,
       do:
         open(state, instance, lookup(state.table, instance), reason, retry_after_ms, elapsed_ms)

  # Empty or off-topic: reachable, so the circuit closes, but it counts, and
  # `:soft_strikes` of them in a row open it like a refusal would.
  defp settle(state, instance, {:error, reason, _retry_after_ms}, elapsed_ms) do
    %{consecutive_soft: soft} = stats = lookup(state.table, instance)
    soft(state, instance, %{stats | consecutive_soft: soft + 1}, reason, elapsed_ms)
  end

  defp soft(
         %{soft_strikes: strikes} = state,
         instance,
         %{consecutive_soft: soft} = stats,
         reason,
         elapsed_ms
       )
       when soft >= strikes,
       do: open(state, instance, stats, reason, nil, elapsed_ms)

  defp soft(state, instance, stats, reason, elapsed_ms) do
    put_stats(state, instance, %{
      failed(stats, reason, elapsed_ms)
      | circuit: :closed,
        consecutive_failures: 0,
        cooldown_until: nil
    })

    closed(state, instance, stats.circuit)
  end

  defp open(state, instance, stats, reason, retry_after_ms, elapsed_ms) do
    consecutive = stats.consecutive_failures + 1
    cooldown = cooldown(state, consecutive, retry_after_ms)

    put_stats(state, instance, %{
      failed(stats, reason, elapsed_ms)
      | circuit: :open,
        consecutive_failures: consecutive,
        cooldown_until: now() + cooldown
    })

    transition(instance, stats.circuit, :open, cooldown)
    state |> cancel_timer(instance) |> start_timer(instance, cooldown)
  end

  defp closed(state, _instance, :closed), do: state

  defp closed(state, instance, from) do
    transition(instance, from, :closed, 0)
    cancel_timer(state, instance)
  end

  defp failed(stats, reason, elapsed_ms),
    do: %{
      stats
      | latency_ms: failed_latency(stats.latency_ms, reason, elapsed_ms),
        failure_rate: @alpha + (1 - @alpha) * stats.failure_rate,
        failures: stats.failures + 1,
        last_outcome: reason
    }

  # The server's own wait when it gave one, else exponential backoff; never
  # longer than the cap.
  defp cooldown(state, _consecutive, retry_after_ms) when is_number(retry_after_ms),
    do: retry_after_ms |> round() |> max(1_000) |> min(state.max_cooldown_ms)

  defp cooldown(state, consecutive, nil),
    do: min(state.cooldown_ms * Integer.pow(2, consecutive - 1), state.max_cooldown_ms)

  defp ewma(nil, sample), do: sample * 1.0
  defp ewma(average, sample), do: @alpha * sample + (1 - @alpha) * average

  # A timeout says the instance is at least that slow; a fast refusal says
  # nothing about how quickly it searches.
  defp failed_latency(average, :timeout, elapsed_ms), do: ewma(average, elapsed_ms)
  defp failed_latency(average, _reason, _elapsed_ms), do: average

  defp transition(instance, from, to, cooldown_ms),
    do:
      Telemetry.emit([:searxng, :circuit], %{count: 1}, %{
        instance: instance,
        from: from,
        to: to,
        cooldown_ms: cooldown_ms
      })

  # --- State helpers ---

  defp start_timer(state, instance, after_ms) do
    generation = make_ref()
    timer = Process.send_after(self(), {:half_open, instance, generation}, after_ms)
    put_in(state.timers[instance], {timer, generation})
  end

  # The timer that ended the cooldown is the current one (the generation
  # matches twice in the head); a stale one does nothing.
  defp half_open(state, instance, generation, {_timer, generation}) do
    update_stats(state, instance, &%{&1 | circuit: :half_open, cooldown_until: nil})
    transition(instance, :open, :half_open, 0)
    %{state | timers: Map.delete(state.timers, instance)}
  end

  defp half_open(state, _instance, _generation, _stale), do: state

  defp cancel_timer(state, instance), do: state.timers |> Map.pop(instance) |> cancelled(state)

  defp cancelled({{timer, _generation}, timers}, state) do
    Process.cancel_timer(timer)
    %{state | timers: timers}
  end

  defp cancelled({nil, _timers}, state), do: state

  defp recorded({nil, _leases}, state, _lease, _outcome, _elapsed_ms), do: state

  defp recorded(popped, state, {instance, ref}, outcome, elapsed_ms) do
    Process.demonitor(ref, [:flush])
    popped |> returned(state) |> settle(instance, outcome, elapsed_ms)
  end

  defp pop_lease(state, ref), do: Map.pop(state.leases, ref)

  defp returned({nil, _leases}, state), do: state

  defp returned({instance, leases}, state) do
    update_stats(state, instance, &%{&1 | in_flight: max(&1.in_flight - 1, 0)})
    %{state | leases: leases}
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_every_ms)

  defp update_stats(state, instance, fun),
    do: put_stats(state, instance, fun.(lookup(state.table, instance)))

  defp put_stats(state, instance, stats), do: :ets.insert(state.table, {instance, stats})

  defp lookup(table, instance), do: table |> :ets.lookup(instance) |> found()

  defp found([{_instance, stats}]), do: stats
  defp found([]), do: fresh()

  defp fresh,
    do: %{
      circuit: :closed,
      latency_ms: nil,
      failure_rate: 0.0,
      successes: 0,
      failures: 0,
      consecutive_failures: 0,
      consecutive_soft: 0,
      cooldown_until: nil,
      in_flight: 0,
      last_outcome: nil,
      last_used_at: nil,
      prior_ms: nil,
      seeded_at: nil
    }

  defp pool(opts), do: Keyword.get(opts, :pool, __MODULE__)
  defp table(pool), do: Server.table(__MODULE__, pool)
  defp now, do: Clock.now_ms()
end
