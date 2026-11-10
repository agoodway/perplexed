defmodule Perplexed.Search.SearXNG do
  @moduledoc """
  Keyless web search through SearXNG metasearch instances, as a
  `Perplexed.Search` provider (`:searxng`). Free: price 0.

  You give it the instances (`searxng_instances:` in the settings, or
  `:instances` per call); `Perplexed.Search.SearXNG.Directory` can pick
  healthy public ones from searx.space, filtered by country. Public
  instances are volunteers' servers: most close the JSON API and run a bot
  limiter, so this sends one HTML search at a time and backs off from any
  instance that refuses. Prefer your own instances, or ones whose operators
  welcome the traffic, for anything beyond experiments.

  ## The waterfall

  `Perplexed.Search.SearXNG.Pool` ranks the instances by what this node has
  measured: response-time and failure averages, plus a cooldown after a
  refusal. A search asks the best `:merge` instances concurrently; each one
  that fails (refused, challenged, timed out, empty) is replaced by the next
  in the ranking, until `:merge` have answered or `:attempts` instances
  have been tried. Every outcome feeds back into the pool, so the ranking
  follows the instances as they speed up, slow down or start refusing.

  With `merge: 1` (the default) the hits are the one instance's, re-ranked;
  with more, the instances' lists are fused by `Perplexed.Search.Fusion`
  (reciprocal rank, engine agreement, query-term coverage).

  ## Options

    * `:instances` - base URLs, or `:auto` for the live public instances
      `Perplexed.Search.SearXNG.Instances` discovers and keeps fresh; default
      the `searxng_instances` setting.
    * `:merge` - instances to combine, default 1.
    * `:attempts` - instances to try at most, default 4.
    * `:timeout_ms` - per-instance wait, default 6000.
    * `:limit` - hits to return, default 8.
    * `:format` - `:html` (default) or `:json` for instances with the JSON
      API open.
    * `:language` (default `"en-US"`), `:categories` (default `"general"`),
      `:time_range` (`"day"`, `"month"`, `"year"`) and `:safesearch` (0-2).
    * `:proxy` - `"http://user:pass@host:port"`, sent through CloakedReq's
      proxy support, for a residential or rotating proxy.
    * `:impersonate` - the CloakedReq browser profile: a profile atom, a
      list to pick from at random per request, or `:random` (the default),
      which picks from a set of current Chrome, Edge, Firefox and Safari
      desktop profiles. A fresh fingerprint per request spreads us across
      what fingerprint-based limiters see; it does nothing against limits
      on the IP, which is what refused us most in testing.
    * `:min_coverage` - lowest average share of query terms in an
      instance's top 5 hits, default 0.4; below it the
      answer counts as `:irrelevant` and the waterfall moves on. Instances
      pass on results from engines that localize to the server's country
      or answer bots with unrelated pages, and fusion can only reorder a
      list, not rescue one that is all off-topic. 0 turns the gate off.
    * `:fusion` - options for `Perplexed.Search.Fusion.fuse/2`.
    * `:jitter` - random spread on each instance's score, 0 to 1, default
      0.25, so searches share the fastest few instances instead of piling
      onto one.
    * `:min_interval_ms` - an instance used this recently is tried only
      after every rested one, default 15000. Public instances refuse a client
      that searches them again too soon (SearXNG's limiter redirects it to
      the start page), so spreading the load is also what keeps them
      answering.
    * `:pool` - the `Pool` to rank with, default the application's.

  Every instance URL passes `Perplexed.UrlGuard` before each search (DNS can
  change after an instance is listed), so an instance on a private network
  is refused as `:unsafe_url`; pass `url_validator:` to allow a self-hosted
  one there.

  Each attempt emits `[:perplexed, :searxng, :attempt]` with `duration`
  (ms) and `hits`, and metadata `instance`, `outcome` and `retry_after_ms`
  (nil unless the instance sent a retry header).
  """

  @behaviour Perplexed.Search

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Clock, Config, Http, TaskSupervisor, Telemetry, UrlGuard}
  alias Perplexed.Search.{Fusion, Hit}
  alias Perplexed.Search.SearXNG.{Instances, Parser, Pool}

  @default_limit 8
  @default_merge 1
  @default_attempts 4
  @timeout_ms 6_000
  @profiles [
    :chrome_146,
    :chrome_147,
    :chrome_148,
    :chrome_149,
    :edge_146,
    :edge_147,
    :edge_148,
    :firefox_149,
    :firefox_150,
    :firefox_151,
    :"safari_26.2",
    :"safari_26.3",
    :"safari_26.4"
  ]
  @language "en-US"
  @min_coverage 0.4
  @jitter 0.25
  @min_interval_ms 15_000
  @gate_depth 5

  @impl true
  def price(_opts), do: 0.0

  @impl true
  def free_when_empty?, do: true

  @impl true
  def search(query, opts) do
    with {:ok, collected} <- collect(query, opts), do: fused(collected, query, opts)
  end

  @doc """
  Runs the waterfall without fusing: `{:ok, {answers, failures}}`, where
  `answers` are `{instance, hits}` in the order the instances answered and
  `failures` are `{instance, reason}`. For custom fusion or experiments;
  `search/2` is `collect/2` followed by `Perplexed.Search.Fusion.fuse/2`.
  """
  @spec collect(String.t(), keyword()) ::
          {:ok, {[{String.t(), [Hit.t()]}], [{String.t(), atom()}]}}
          | {:error, Perplexed.error()}
  def collect(query, opts \\ [])

  def collect(query, opts) when is_present(query),
    do: opts |> instances() |> collected(String.trim(query), opts)

  def collect(_query, _opts), do: {:error, {:invalid_request, %{reason: :empty_query}}}

  defp collected([], _query, _opts),
    do: {:error, {:invalid_request, %{reason: :no_searxng_instances}}}

  defp collected(instances, query, opts), do: {:ok, waterfall(query, instances, opts)}

  defp rank_options(opts),
    do: [
      pool: pool(opts),
      jitter: Keyword.get(opts, :jitter, @jitter),
      min_interval_ms: Keyword.get(opts, :min_interval_ms, @min_interval_ms)
    ]

  defp instances(opts),
    do:
      opts
      |> Keyword.get_lazy(:instances, fn -> Config.get(:searxng_instances, []) end)
      |> resolved(opts)

  defp resolved(:auto, opts),
    do: opts |> Keyword.take([:store, :await_ms]) |> Instances.urls() |> resolved(opts)

  defp resolved(urls, _opts) when is_list(urls), do: Enum.map(urls, &base_url/1)

  defp base_url(url), do: String.trim_trailing(url, "/") <> "/"

  # Leases `merge` instances at a time from the pool, refilling a failed
  # slot with the next best, until enough answered, the attempt budget is
  # spent, or every remaining instance is cooling down.
  defp waterfall(query, instances, opts) do
    climb(%{
      query: query,
      candidates: instances,
      needed: Keyword.get(opts, :merge, @default_merge),
      budget: Keyword.get(opts, :attempts, @default_attempts),
      answers: [],
      failures: [],
      opts: opts
    })
  end

  defp climb(%{needed: needed, budget: budget} = climb) when needed <= 0 or budget <= 0,
    do: climbed(climb)

  defp climb(%{candidates: candidates, needed: needed, budget: budget, opts: opts} = climb),
    do: candidates |> Pool.checkout(min(needed, budget), rank_options(opts)) |> leased(climb)

  # Every remaining instance is open or busy with a trial.
  defp leased([], climb), do: climbed(climb)

  defp leased(leases, %{query: query, opts: opts} = climb) do
    leases
    |> run(query, opts)
    |> Enum.reduce(%{climb | budget: climb.budget - length(leases)}, &tally/2)
    |> Map.update!(:candidates, &(&1 -- Enum.map(leases, fn {instance, _ref} -> instance end)))
    |> climb()
  end

  defp tally({instance, {:ok, hits}}, climb),
    do: %{climb | answers: [{instance, hits} | climb.answers], needed: climb.needed - 1}

  defp tally({instance, {:error, reason}}, climb),
    do: %{climb | failures: [{instance, reason} | climb.failures]}

  defp climbed(%{answers: answers, failures: failures}),
    do: {Enum.reverse(answers), Enum.reverse(failures)}

  defp run(leases, query, opts) do
    TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(leases, &attempt(query, &1, opts),
      timeout: timeout_ms(opts) + 1_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(leases)
    |> Enum.map(&settled(&1, opts))
  end

  defp settled({{:ok, {_instance, _result} = attempted}, _lease}, _opts), do: attempted

  # The task died or overran its deadline before recording; record for it.
  defp settled({{:exit, _reason}, {instance, _ref} = lease}, opts) do
    Pool.record(lease, {:error, :timeout}, timeout_ms(opts), pool: pool(opts))

    {instance, {:error, :timeout}}
  end

  defp attempt(query, {instance, _ref} = lease, opts) do
    {{result, retry_after_ms}, elapsed} =
      Clock.timed(fn -> instance |> UrlGuard.check(opts) |> searched(query, opts) end)

    Pool.record(lease, pool_outcome(result, retry_after_ms), elapsed, pool: pool(opts))

    Telemetry.emit([:searxng, :attempt], %{duration: elapsed, hits: hit_count(result)}, %{
      instance: instance,
      outcome: outcome(result),
      retry_after_ms: retry_after_ms
    })

    {instance, result}
  end

  # Checked on every search, not just at discovery: an instance's DNS can
  # change to point at a private network after it was listed.
  defp searched({:ok, instance}, query, opts) do
    format = Keyword.get(opts, :format, :html)

    {result, retry_after_ms} =
      instance |> request(query, format, opts) |> Req.request() |> response(format)

    {relevant(result, query, opts), retry_after_ms}
  end

  defp searched({:error, _unsafe}, _query, _opts), do: {{:error, :unsafe_url}, nil}

  defp request(instance, query, format, opts),
    do:
      new_request(
        [
          url: instance <> "search",
          params: params(query, format, opts),
          receive_timeout: timeout_ms(opts)
        ],
        opts
      )

  @doc false
  # A request to an instance as every SearXNG call makes it: no retries or
  # redirects (a redirect is the limiter's answer), raw body, the caller's
  # language, proxy and browser profile, and `:req_options` last.
  @spec new_request(keyword(), keyword()) :: Req.Request.t()
  def new_request(request_options, opts) do
    [
      headers: [{"accept-language", "#{Keyword.get(opts, :language, @language)},en;q=0.8"}],
      retry: false,
      redirect: false,
      decode_body: false
    ]
    |> Keyword.merge(request_options)
    |> Keyword.merge(proxy(Keyword.get(opts, :proxy)))
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
    |> transport(opts)
  end

  defp params(query, format, opts) do
    [
      q: query,
      language: Keyword.get(opts, :language, @language),
      categories: Keyword.get(opts, :categories, "general"),
      safesearch: Keyword.get(opts, :safesearch, 1),
      time_range: Keyword.get(opts, :time_range),
      format: format_param(format)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp format_param(:json), do: "json"
  defp format_param(:html), do: nil

  # Req's `plug:` (tests) replaces the adapter, so impersonation only wraps
  # real network requests.
  defp transport(request, opts),
    do:
      opts |> Keyword.get(:req_options, []) |> Keyword.has_key?(:plug) |> transport(request, opts)

  defp transport(true = _plugged, request, _opts), do: request

  defp transport(false = _plugged, request, opts),
    do:
      CloakedReq.attach(request,
        impersonate: opts |> Keyword.get(:impersonate, :random) |> profile()
      )

  @doc false
  # The profile for one request.
  @spec profile(atom() | [atom()]) :: atom()
  def profile(:random), do: Enum.random(@profiles)
  def profile([_ | _] = profiles), do: Enum.random(profiles)
  def profile(profile) when is_atom(profile), do: profile

  @doc false
  # `"http://user:pass@host:port"` as Req connect options CloakedReq honors.
  @spec proxy(String.t() | nil) :: keyword()
  def proxy(nil), do: []

  def proxy(url) when is_binary(url) do
    %URI{scheme: scheme, host: host, port: port, userinfo: userinfo} = URI.parse(url)

    [
      connect_options: [
        proxy: {proxy_scheme(scheme), host, port, []},
        proxy_headers: proxy_auth(userinfo)
      ]
    ]
  end

  defp proxy_scheme("https"), do: :https
  defp proxy_scheme(_http), do: :http

  defp proxy_auth(nil), do: []

  defp proxy_auth(userinfo),
    do: [{"proxy-authorization", "Basic " <> Base.encode64(URI.decode(userinfo))}]

  # An answer whose top hits barely mention the query is a soft failure.
  defp relevant({:ok, hits} = answer, query, opts),
    do:
      opts
      |> Keyword.get(:min_coverage, @min_coverage)
      |> gate(answer, Fusion.mean_coverage(hits, query, @gate_depth))

  defp relevant(error, _query, _opts), do: error

  defp gate(min, answer, mean) when min <= 0 or mean >= min, do: answer
  defp gate(_min, _answer, _mean), do: {:error, :irrelevant}

  defp response({:ok, %Req.Response{status: status, body: body} = response}, format),
    do: {Parser.parse(status, body, format), Http.retry_after_ms(response)}

  defp response({:error, %Req.TransportError{reason: :timeout}}, _format),
    do: {{:error, :timeout}, nil}

  defp response({:error, _exception}, _format), do: {{:error, :transport}, nil}

  defp pool_outcome({:ok, hits}, _retry_after_ms), do: {:ok, length(hits)}
  defp pool_outcome({:error, reason}, retry_after_ms), do: {:error, reason, retry_after_ms}

  defp outcome({:ok, _hits}), do: :ok
  defp outcome({:error, reason}), do: reason

  defp hit_count({:ok, hits}), do: length(hits)
  defp hit_count({:error, _reason}), do: 0

  defp fused({[], []}, _query, _opts),
    do: {:error, {:rate_limited, %{reason: :all_searxng_instances_cooling}}}

  defp fused({[], failures}, _query, _opts),
    do: {:error, {:upstream, %{reason: :no_searxng_answer, attempts: failures}}}

  defp fused({answers, _failures}, query, opts) do
    fusion =
      opts
      |> Keyword.get(:fusion, [])
      |> Keyword.put_new(:query, query)
      |> Keyword.put_new(:limit, Keyword.get(opts, :limit, @default_limit))

    {:ok, answers |> Enum.map(fn {_instance, hits} -> hits end) |> Fusion.fuse(fusion)}
  end

  defp pool(opts), do: Keyword.get(opts, :pool, Pool)
  defp timeout_ms(opts), do: Keyword.get(opts, :timeout_ms, @timeout_ms)
end
