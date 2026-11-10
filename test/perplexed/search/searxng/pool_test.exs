defmodule Perplexed.Search.SearXNG.PoolTest do
  use ExUnit.Case, async: true

  import Perplexed.Fixtures, only: [capture_telemetry: 1, measure: 4, start_pool: 1]

  alias Perplexed.Search.SearXNG.Pool

  setup do
    capture_telemetry([[:perplexed, :searxng, :circuit]])
    pool = start_pool(cooldown_ms: 1_000, max_cooldown_ms: 8_000)
    %{pool: pool, opts: [pool: pool]}
  end

  # An instance URL no other test uses, so global telemetry handlers can
  # tell this test's events apart.
  defp instance, do: "https://#{System.unique_integer([:positive])}.pool.test/"

  # Delivers the cooldown timer now instead of waiting it out.
  defp fire_cooldown(pool, instance) do
    %{timers: %{^instance => {timer, generation}}} = :sys.get_state(pool)
    Process.cancel_timer(timer)
    send(pool, {:half_open, instance, generation})
    :sys.get_state(pool)
  end

  defp cooldown_of(pool, instance, outcome) do
    measure(instance, outcome, 50, pool)

    assert_received {:telemetry, _event, _measurements,
                     %{instance: ^instance, to: :open, cooldown_ms: ms}}

    ms
  end

  # A `:random` stand-in returning `draws` in turn.
  defp draws(draws) do
    {:ok, agent} = Agent.start_link(fn -> draws end)
    fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end
  end

  describe "ranking" do
    test "orders measured instances fastest first", %{pool: pool, opts: opts} do
      measure("https://slow/", {:ok, 10}, 3_000, pool)
      measure("https://fast/", {:ok, 10}, 400, pool)

      assert Pool.rank(["https://slow/", "https://fast/"], opts) ==
               ["https://fast/", "https://slow/"]
    end

    test "tries an unmeasured instance between fast and slow ones", %{pool: pool, opts: opts} do
      measure("https://fast/", {:ok, 10}, 400, pool)
      measure("https://slow/", {:ok, 10}, 5_000, pool)

      assert Pool.rank(["https://slow/", "https://new/", "https://fast/"], opts) ==
               ["https://fast/", "https://new/", "https://slow/"]
    end

    test "uses a seeded prior for an unmeasured instance", %{pool: pool, opts: opts} do
      measure("https://measured/", {:ok, 10}, 800, pool)
      Pool.seed([{"https://seeded/", 300}], opts)

      assert hd(Pool.rank(["https://measured/", "https://seeded/"], opts)) == "https://seeded/"
    end

    test "keeps learning: a fast instance that slows down drops", %{pool: pool, opts: opts} do
      measure("https://a/", {:ok, 10}, 300, pool)
      measure("https://b/", {:ok, 10}, 900, pool)
      assert hd(Pool.rank(["https://a/", "https://b/"], opts)) == "https://a/"

      for _ <- 1..4, do: measure("https://a/", {:ok, 10}, 4_000, pool)
      assert hd(Pool.rank(["https://a/", "https://b/"], opts)) == "https://b/"
    end

    test "jitter can lift a close second over the leader", %{pool: pool, opts: opts} do
      measure("https://a/", {:ok, 10}, 1_000, pool)
      measure("https://b/", {:ok, 10}, 1_100, pool)
      candidates = ["https://a/", "https://b/"]

      # The same factor on every score keeps the order...
      assert Pool.rank(candidates, opts ++ [jitter: 0.3, random: draws([0.5, 0.5])]) ==
               candidates

      # ...while draws against a and for b flip it.
      assert Pool.rank(candidates, opts ++ [jitter: 0.3, random: draws([0.99, 0.0])]) ==
               ["https://b/", "https://a/"]
    end

    test "jitter never lifts a much slower instance over a fast one", %{pool: pool, opts: opts} do
      measure("https://fast/", {:ok, 10}, 300, pool)
      measure("https://slow/", {:ok, 10}, 3_000, pool)

      # The worst draw for fast against the best for slow.
      ranked =
        Pool.rank(
          ["https://fast/", "https://slow/"],
          opts ++ [jitter: 0.25, random: draws([0.999, 0.0])]
        )

      assert hd(ranked) == "https://fast/"
    end

    test "an instance used within min_interval_ms ranks after rested ones", %{
      pool: pool,
      opts: opts
    } do
      measure("https://fast/", {:ok, 10}, 200, pool)
      resting = Keyword.put(opts, :min_interval_ms, 60_000)

      assert Pool.rank(["https://fast/", "https://rested/"], resting) ==
               ["https://rested/", "https://fast/"]
    end
  end

  describe "circuit breaker" do
    test "a refusal opens the circuit and takes the instance out of rotation", %{
      pool: pool,
      opts: opts
    } do
      measure("https://x/", {:error, :rate_limited}, 50, pool)

      assert %{circuit: :open, consecutive_failures: 1} = Pool.stats("https://x/", pool)
      assert Pool.rank(["https://x/"], opts) == []
      assert Pool.checkout(["https://x/"], 1, opts) == []
    end

    test "the backoff doubles per refusal in a row, up to the cap", %{pool: pool} do
      x = instance()

      cooldowns =
        for _ <- 1..5 do
          ms = cooldown_of(pool, x, {:error, :blocked})
          fire_cooldown(pool, x)
          ms
        end

      assert cooldowns == [1_000, 2_000, 4_000, 8_000, 8_000]
    end

    test "honors the server's Retry-After over the backoff", %{pool: pool} do
      assert cooldown_of(pool, instance(), {:error, :rate_limited, 5_000}) == 5_000
    end

    test "rounds a fractional Retry-After and keeps it at least a second", %{pool: pool} do
      assert cooldown_of(pool, instance(), {:error, :rate_limited, 1_500.6}) == 1_501
      assert cooldown_of(pool, instance(), {:error, :rate_limited, 10}) == 1_000
    end

    test "caps a long Retry-After at max_cooldown_ms", %{pool: pool} do
      assert cooldown_of(pool, instance(), {:error, :rate_limited, 3_600_000}) == 8_000
    end

    test "after the cooldown it half-opens for a single trial", %{pool: pool, opts: opts} do
      measure("https://x/", {:error, :challenge}, 50, pool)
      fire_cooldown(pool, "https://x/")

      assert Pool.stats("https://x/", pool).circuit == :half_open
      assert [{"https://x/", _ref} = trial] = Pool.checkout(["https://x/"], 1, opts)
      assert Pool.checkout(["https://x/"], 1, opts) == []

      Pool.record(trial, {:ok, 10}, 400, opts)
      assert %{circuit: :closed, consecutive_failures: 0} = Pool.stats("https://x/", pool)
    end

    test "a failed trial opens it again", %{pool: pool} do
      measure("https://x/", {:error, :blocked}, 50, pool)
      fire_cooldown(pool, "https://x/")
      measure("https://x/", {:error, :blocked}, 50, pool)

      assert %{circuit: :open, consecutive_failures: 2} = Pool.stats("https://x/", pool)
    end

    test "the timer puts it back in rotation on its own" do
      pool = start_pool(cooldown_ms: 20)
      x = instance()

      measure(x, {:error, :blocked}, 50, pool)
      assert Pool.rank([x], pool: pool) == []

      assert_receive {:telemetry, _event, _measurements, %{instance: ^x, to: :half_open}}, 1_000
      assert Pool.rank([x], pool: pool) == [x]
    end

    test "an empty or off-topic answer counts against it without a cooldown", %{pool: pool} do
      measure("https://x/", {:error, :irrelevant}, 900, pool)

      assert %{circuit: :closed, cooldown_until: nil, failures: 1, failure_rate: rate} =
               Pool.stats("https://x/", pool)

      assert rate > 0
    end

    test "three off-topic answers in a row cool it down like a refusal", %{pool: pool} do
      for _ <- 1..2, do: measure("https://x/", {:error, :irrelevant}, 300, pool)
      assert Pool.stats("https://x/", pool).circuit == :closed

      measure("https://x/", {:error, :irrelevant}, 300, pool)
      assert %{circuit: :open, last_outcome: :irrelevant} = Pool.stats("https://x/", pool)
    end

    test "a real answer resets the off-topic streak", %{pool: pool} do
      for _ <- 1..2, do: measure("https://x/", {:error, :no_results}, 300, pool)
      measure("https://x/", {:ok, 10}, 300, pool)
      for _ <- 1..2, do: measure("https://x/", {:error, :irrelevant}, 300, pool)

      assert %{circuit: :closed, consecutive_soft: 2} = Pool.stats("https://x/", pool)
    end

    test "emits every transition", %{pool: pool} do
      x = instance()

      measure(x, {:error, :blocked}, 50, pool)
      fire_cooldown(pool, x)
      measure(x, {:ok, 10}, 300, pool)

      assert_received {:telemetry, _, _, %{instance: ^x, from: :closed, to: :open}}
      assert_received {:telemetry, _, _, %{instance: ^x, from: :open, to: :half_open}}
      assert_received {:telemetry, _, _, %{instance: ^x, from: :half_open, to: :closed}}
    end
  end

  describe "leases" do
    test "concurrent checkouts get different half-open instances", %{pool: pool, opts: opts} do
      for instance <- ["https://a/", "https://b/"] do
        measure(instance, {:error, :blocked}, 50, pool)
        fire_cooldown(pool, instance)
      end

      candidates = ["https://a/", "https://b/"]
      [{first, _}] = Pool.checkout(candidates, 1, opts)
      [{second, _}] = Pool.checkout(candidates, 1, opts)

      assert Enum.sort([first, second]) == candidates
      assert Pool.checkout(candidates, 1, opts) == []
    end

    test "a caller that dies gives its leases back", %{pool: pool, opts: opts} do
      measure("https://x/", {:error, :blocked}, 50, pool)
      fire_cooldown(pool, "https://x/")

      {pid, ref} = spawn_monitor(fn -> Pool.checkout(["https://x/"], 1, opts) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # The pool has handled the caller's :DOWN once this call returns.
      :sys.get_state(pool)
      assert Pool.stats("https://x/", pool).in_flight == 0
      assert [_trial] = Pool.checkout(["https://x/"], 1, opts)
    end

    test "a lease is recorded once", %{pool: pool, opts: opts} do
      [lease] = Pool.checkout(["https://x/"], 1, opts)
      Pool.record(lease, {:ok, 10}, 300, opts)
      Pool.record(lease, {:ok, 10}, 300, opts)

      assert %{successes: 1, in_flight: 0} = Pool.stats("https://x/", pool)
    end
  end

  describe "sweep" do
    test "forgets idle instances, including seeded ones never used" do
      pool = start_pool(forget_after_ms: 0)
      measure("https://used/", {:ok, 10}, 300, pool)
      Pool.seed([{"https://seeded/", 500}], pool: pool)

      send(pool, :sweep)
      :sys.get_state(pool)

      assert Pool.snapshot(pool: pool) == []
    end

    test "keeps instances with a lease out or a cooldown running" do
      pool = start_pool(forget_after_ms: 0)
      [_lease] = Pool.checkout(["https://leased/"], 1, pool: pool)
      measure("https://cooling/", {:error, :blocked}, 50, pool)

      send(pool, :sweep)
      :sys.get_state(pool)

      kept = [pool: pool] |> Pool.snapshot() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert kept == ["https://cooling/", "https://leased/"]
    end
  end

  test "ignores stray messages", %{pool: pool} do
    send(pool, :unexpected)
    assert %{} = :sys.get_state(pool)
  end
end
