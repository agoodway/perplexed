defmodule Perplexed.Search.SearXNG.Directory do
  @moduledoc """
  Picks public SearXNG instances from searx.space's daily health check
  (`https://searx.space/data/instances.json`).

  Keeps instances on the open web (not Tor or I2P) that answered HTTP 200
  and passed at least `:min_success` percent of searx.space's test searches,
  optionally only those hosted in `:countries` (ISO codes such as `"US"` or
  `"DE"`, from the network searx.space resolved each instance's IPs to).
  Each entry carries searx.space's median search time, which `seed/1` hands
  to `Perplexed.Search.SearXNG.Pool` as a prior until this node has measured
  the instance itself. searx.space measures from Germany, so the median is a
  starting point, not your latency.

  `probe/2` checks from here which instances are up right now, with one
  light request to each start page (never a search), and `discover/1`
  does the whole job: fetch, filter, probe, keep the live ones and seed the
  pool. `Perplexed.Search.SearXNG.Instances` runs `discover/1` on a timer,
  and `mix perplexed.searxng.instances` runs it from the shell. A live start
  page does not promise the instance will search for you, since SearXNG's
  limiter acts on `/search`; the pool's circuit breaker covers that.
  """

  alias Perplexed.{Clock, TaskSupervisor, UrlGuard}
  alias Perplexed.Search.SearXNG
  alias Perplexed.Search.SearXNG.{Parser, Pool}

  @url "https://searx.space/data/instances.json"
  @probe_timeout_ms 5_000
  @probe_concurrency 8
  @generator ~r/<meta[^>]+name="generator"[^>]+content="searxng/i

  @type probe :: %{status: :alive | :challenge | :blocked | :down, latency_ms: non_neg_integer()}

  @type entry :: %{
          required(:url) => String.t(),
          required(:countries) => [String.t()],
          required(:median_ms) => non_neg_integer() | nil,
          required(:engines) => [String.t()],
          optional(:probe) => probe()
        }

  @doc """
  Fetches the directory, probes what it lists, seeds the pool with the
  live instances and returns them, fastest first.

  Takes `fetch/1`'s and `probe/2`'s options, plus `probe: false` to skip
  probing (every listed instance is kept) and `:pool`.
  """
  @spec discover(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def discover(opts \\ []) do
    with {:ok, entries} <- fetch(opts) do
      live = entries |> probed(Keyword.get(opts, :probe, true), opts) |> alive()
      seed(live, opts)
      {:ok, live}
    end
  end

  defp probed(entries, true = _probe?, opts), do: probe(entries, opts)
  defp probed(entries, false = _probe?, _opts), do: entries

  defp alive(entries), do: Enum.filter(entries, &alive?/1)

  @doc "Whether `entry` is worth using: probed alive, or not probed at all."
  @spec alive?(entry()) :: boolean()
  def alive?(%{probe: %{status: :alive}}), do: true
  def alive?(%{probe: _not_alive}), do: false
  def alive?(_unprobed), do: true

  @doc """
  Checks each entry's start page concurrently and adds its `:probe`:
  `:alive` (a SearXNG page), `:challenge` (a bot check in front of it),
  `:blocked` (refused or redirected) or `:down`, with the round trip in ms.
  Live entries come back fastest first by searx.space median plus that
  round trip; the rest follow.

  Options: `:timeout_ms` (default #{@probe_timeout_ms}), `:max_concurrency`
  (default #{@probe_concurrency}), and the request options SearXNG searches
  take (`:proxy`, `:impersonate`, `:req_options`).
  """
  @spec probe([entry()], keyword()) :: [entry()]
  def probe(entries, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)

    TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      entries,
      &Map.put(&1, :probe, ping(&1.url, timeout, opts)),
      max_concurrency: Keyword.get(opts, :max_concurrency, @probe_concurrency),
      timeout: timeout + 1_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(entries)
    |> Enum.map(&pinged(&1, timeout))
    |> Enum.sort_by(&probe_order/1)
  end

  # The URL guard runs first: an instance from the directory is a third
  # party's hostname, which can point anywhere, including a private network.
  defp ping(url, timeout, opts) do
    {status, ms} = Clock.timed(fn -> url |> UrlGuard.check(opts) |> pinged_url(timeout, opts) end)
    %{status: status, latency_ms: ms}
  end

  defp pinged_url({:ok, url}, timeout, opts),
    do:
      [url: url, receive_timeout: timeout]
      |> SearXNG.new_request(opts)
      |> Req.request()
      |> probe_status()

  defp pinged_url({:error, _unsafe}, _timeout, _opts), do: :blocked

  defp pinged({{:ok, entry}, _entry}, _timeout), do: entry

  defp pinged({{:exit, _reason}, entry}, timeout),
    do: Map.put(entry, :probe, %{status: :down, latency_ms: timeout})

  defp probe_status({:ok, %Req.Response{status: 200, body: body}}),
    do: page_status(Regex.match?(@generator, body))

  defp probe_status({:ok, %Req.Response{status: status}}),
    do: status |> Parser.status_reason() |> refused()

  defp probe_status({:error, _exception}), do: :down

  defp refused(reason) when reason in [:rate_limited, :blocked], do: :blocked
  defp refused(_down), do: :down

  defp page_status(true = _searxng_page), do: :alive
  defp page_status(false = _searxng_page), do: :challenge

  defp probe_order(%{probe: %{status: :alive, latency_ms: latency}} = entry),
    do: {0, (entry.median_ms || 0) + latency}

  defp probe_order(%{probe: %{latency_ms: latency}}), do: {1, latency}

  @doc """
  Fetches and filters the directory.

  ## Options

    * `:countries` - ISO country codes to keep, default all.
    * `:min_success` - lowest test-search success percentage, default 90.
    * `:max_median_ms` - slowest median search time to keep, default none.
    * `:req_options` - merged into the Req call (tests pass `plug:`).
  """
  @spec fetch(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def fetch(opts \\ []) do
    [url: @url, receive_timeout: 90_000, retry: :transient]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.get()
    |> fetched(opts)
  end

  defp fetched({:ok, %Req.Response{status: 200, body: %{"instances" => _} = body}}, opts),
    do: {:ok, entries(body, opts)}

  defp fetched({:ok, %Req.Response{status: status}}, _opts),
    do: {:error, {:upstream, %{status: status}}}

  defp fetched({:error, exception}, _opts),
    do: {:error, {:transport, %{reason: Exception.message(exception)}}}

  @doc "Filters a decoded `instances.json` body; see `fetch/1` for the options."
  @spec entries(map(), keyword()) :: [entry()]
  def entries(%{"instances" => instances} = body, opts \\ []) do
    cidrs = Map.get(body, "cidrs", %{})
    countries = opts |> Keyword.get(:countries) |> upcased()
    min_success = Keyword.get(opts, :min_success, 90)
    max_median = Keyword.get(opts, :max_median_ms)

    instances
    |> Enum.filter(fn {url, info} -> plain_https?(url) and healthy?(info, min_success) end)
    |> Enum.map(fn {url, info} -> entry(url, info, cidrs) end)
    |> Enum.filter(&(in_countries?(&1, countries) and fast_enough?(&1, max_median)))
    |> Enum.sort_by(&(&1.median_ms || :infinity))
  end

  @doc """
  Seeds the pool with each entry's prior: searx.space's median search time,
  plus the probe's round trip from here when the entry was probed.
  """
  @spec seed([entry()], keyword()) :: :ok
  def seed(entries, opts \\ []),
    do: entries |> Enum.flat_map(&prior/1) |> Pool.seed(opts)

  defp prior(%{median_ms: nil}), do: []
  defp prior(%{url: url, median_ms: median, probe: %{latency_ms: rtt}}), do: [{url, median + rtt}]
  defp prior(%{url: url, median_ms: median}), do: [{url, median}]

  @doc "The entries' URLs, for the `:instances` option."
  @spec urls([entry()]) :: [String.t()]
  def urls(entries), do: Enum.map(entries, & &1.url)

  # Searches go to these hosts, so only a plain https base URL is used: no
  # cleartext, no credentials, query or fragment.
  defp plain_https?(url), do: url |> URI.parse() |> plain_https_uri?()

  defp plain_https_uri?(%URI{
         scheme: "https",
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil
       })
       when is_binary(host),
       do: true

  defp plain_https_uri?(%URI{}), do: false

  defp healthy?(info, min_success) do
    info["network_type"] == "normal" and get_in(info, ["http", "status_code"]) == 200 and
      (get_in(info, ["timing", "search", "success_percentage"]) || 0) >= min_success
  end

  defp entry(url, info, cidrs) do
    %{
      url: url,
      countries: countries(info, cidrs),
      median_ms: median_ms(get_in(info, ["timing", "search", "all", "median"])),
      engines: get_in(info, ["timing", "search", "working_engine_names"]) || []
    }
  end

  defp countries(info, cidrs) do
    info
    |> ips()
    |> Enum.map(&get_in(cidrs, [&1["asn_cidr"], "network_country"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ips(%{"network" => %{"ips" => %{} = ips}}), do: Map.values(ips)
  defp ips(_info), do: []

  defp median_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp median_ms(_missing), do: nil

  defp upcased(nil), do: nil
  defp upcased(codes), do: Enum.map(codes, &String.upcase/1)

  defp in_countries?(_entry, nil), do: true
  defp in_countries?(%{countries: found}, wanted), do: Enum.any?(found, &(&1 in wanted))

  defp fast_enough?(_entry, nil), do: true
  defp fast_enough?(%{median_ms: nil}, _max), do: false
  defp fast_enough?(%{median_ms: median}, max), do: median <= max
end
