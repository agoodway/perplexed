defmodule Perplexed.Search.SearXNG.Instances do
  @moduledoc """
  The live set of public SearXNG instances, discovered instead of
  hard-coded. Set `searxng_instances: :auto` and `Perplexed.Search.SearXNG`
  asks this store for its instances.

  The store starts empty. The first search that needs it runs
  `Perplexed.Search.SearXNG.Directory.discover/1` (fetch searx.space,
  filter, probe each start page, seed the pool) and waits for it;
  searches that arrive meanwhile wait on the same discovery rather than
  starting their own. After that it refreshes in the background every
  `searxng_refresh_ms` (default daily), keeping the last good list if a
  refresh fails and retrying a failed refresh sooner. Discovery options
  come from the `searxng_discovery` setting, such as
  `[countries: ["US", "CA"], max_median_ms: 2_500]`.

  Discovery runs in a task under `Perplexed.TaskSupervisor`, so a slow
  searx.space never blocks the store, and a crash in it is logged as a
  failed refresh. Each finished refresh emits
  `[:perplexed, :searxng, :instances]` with `count` and metadata `result`.
  """

  use GenServer

  alias Perplexed.{Config, TaskSupervisor, Telemetry}
  alias Perplexed.Search.SearXNG.{Directory, Server}

  @refresh_ms 24 * 60 * 60_000
  @retry_ms 5 * 60_000
  @await_ms 120_000
  @discovery_timeout_ms 180_000

  @type status :: %{
          count: non_neg_integer(),
          refreshed_at: DateTime.t() | nil,
          refreshing?: boolean(),
          last_error: term()
        }

  # --- Public API ---

  @doc """
  Starts the store. Options: `:name` (default `#{inspect(__MODULE__)}`),
  `:discovery` (options for `Directory.discover/1`, merged over the
  `searxng_discovery` setting), `:refresh_ms` and `:retry_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Server.start_link(__MODULE__, opts)

  @doc """
  The live instances' URLs, fastest first, discovering them first when the
  store has never been filled (waiting up to `:await_ms`, default
  #{@await_ms}). Options: `:store`, `:await_ms`.
  """
  @spec urls(keyword()) :: [String.t()]
  def urls(opts \\ []), do: opts |> entries() |> Directory.urls()

  @doc "Like `urls/1`, with each instance's directory entry and probe."
  @spec entries(keyword()) :: [Directory.entry()]
  def entries(opts \\ []) do
    table = opts |> store() |> table()
    filled(cached_entries(table), attempted?(table), opts)
  end

  # Only a store that never finished a discovery makes the caller wait for
  # one. After that an empty store answers at once and its retry timer
  # rediscovers, so searches during an outage do not each start a discovery.
  defp filled([], false = _attempted, opts), do: refresh(Keyword.put_new(opts, :await, true))
  defp filled(entries, _attempted, _opts), do: entries

  @doc """
  Refreshes now. With `await: true`, waits and returns the entries;
  otherwise starts the refresh in the background and returns `[]`.
  """
  @spec refresh(keyword()) :: [Directory.entry()]
  def refresh(opts \\ []), do: refresh(store(opts), Keyword.get(opts, :await, false), opts)

  # A discovery that outlasts the wait leaves the caller with no instances,
  # not an exit.
  defp refresh(store, true = _await, opts) do
    GenServer.call(store, :refresh, Keyword.get(opts, :await_ms, @await_ms))
  catch
    :exit, _timeout -> []
  end

  defp refresh(store, false = _await, _opts) do
    GenServer.cast(store, :refresh)
    []
  end

  @doc "What the store holds and when it last refreshed."
  @spec status(keyword()) :: status()
  def status(opts \\ []), do: GenServer.call(store(opts), :status)

  # --- Callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = Server.open_table(__MODULE__, name)

    {:ok,
     %{
       name: name,
       table: table,
       discovery: Keyword.get(opts, :discovery, []),
       refresh_ms:
         Keyword.get_lazy(opts, :refresh_ms, fn ->
           Config.get(:searxng_refresh_ms, @refresh_ms)
         end),
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       discovery_timeout_ms: Keyword.get(opts, :discovery_timeout_ms, @discovery_timeout_ms),
       task: nil,
       waiters: [],
       timer: nil,
       refreshed_at: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:refresh, from, state),
    do: {:noreply, state |> start_discovery() |> Map.update!(:waiters, &[from | &1])}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       count: state.table |> cached_entries() |> length(),
       refreshed_at: state.refreshed_at,
       refreshing?: match?(%Task{}, state.task),
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_discovery(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, start_discovery(%{state | timer: nil})}

  # The discovery task answered.
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, result)}
  end

  # Discovery overran its deadline: stop it and keep what the store has.
  def handle_info({:discovery_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, finished(state, {:error, :timeout})}
  end

  # The discovery task crashed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, finished(state, {:error, {:discovery_crashed, reason}})}

  def handle_info(_stray, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Server.close_table(__MODULE__, state.name)

  # --- Discovery ---

  # One discovery at a time; later callers wait on the one running.
  defp start_discovery(%{task: %Task{}} = state), do: state

  defp start_discovery(state) do
    opts = :searxng_discovery |> Config.get([]) |> Keyword.merge(state.discovery)

    task = Task.Supervisor.async_nolink(TaskSupervisor, fn -> Directory.discover(opts) end)
    Process.send_after(self(), {:discovery_timeout, task.ref}, state.discovery_timeout_ms)
    %{cancel(state) | task: task}
  end

  defp finished(state, {:ok, entries}) do
    :ets.insert(state.table, [{:entries, entries}, {:attempted, true}])
    emit(length(entries), :ok)

    state
    |> reply_all(entries)
    |> Map.merge(%{task: nil, refreshed_at: DateTime.utc_now(), last_error: nil})
    |> schedule(state.refresh_ms)
  end

  # Keep the last good list; try again sooner.
  defp finished(state, {:error, reason}) do
    :ets.insert(state.table, {:attempted, true})
    emit(0, :error)

    state
    |> reply_all(cached_entries(state.table))
    |> Map.merge(%{task: nil, last_error: reason})
    |> schedule(state.retry_ms)
  end

  defp reply_all(%{waiters: waiters} = state, entries) do
    Enum.each(waiters, &GenServer.reply(&1, entries))
    %{state | waiters: []}
  end

  defp schedule(state, after_ms),
    do: %{state | timer: Process.send_after(self(), :refresh, after_ms)}

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp emit(count, result),
    do: Telemetry.emit([:searxng, :instances], %{count: count}, %{result: result})

  defp cached_entries(table), do: table |> :ets.lookup(:entries) |> stored()

  defp stored([{:entries, entries}]), do: entries
  defp stored([]), do: []

  defp attempted?(table), do: :ets.member(table, :attempted)

  defp store(opts), do: Keyword.get(opts, :store, __MODULE__)
  defp table(store), do: Server.table(__MODULE__, store)
end
