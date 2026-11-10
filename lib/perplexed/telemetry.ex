defmodule Perplexed.Telemetry do
  @moduledoc """
  `:telemetry` events Perplexed emits. Attach handlers to track spend or to
  be told when a provider needs attention.

  Searches and scrapes are spans: each emits `:start`, then `:stop` (or
  `:exception` if it raised), with `:telemetry.span/3`'s standard
  `duration` (native time units) on stop.

  | Event                                | Measurements                       | Metadata                                  |
  | ------------------------------------ | ---------------------------------- | ----------------------------------------- |
  | `[:perplexed, :search, :start]`      | `system_time`                      | `provider`, `query`                       |
  | `[:perplexed, :search, :stop]`       | `duration`, `cost`, `hits`         | `provider`, `query`, `result`             |
  | `[:perplexed, :scrape, :start]`      | `system_time`                      | `url`                                     |
  | `[:perplexed, :scrape, :stop]`       | `duration`, `cost`, `browser_ms`   | `url`, `tier`, `attempts`, `result`       |
  | `[:perplexed, :model]`               | token counts, `cost` (when priced) | `model`, `phase`                          |
  | `[:perplexed, :search, :attempt]`    | `duration` (ms), `cost`            | `provider`, `outcome`, `billable`         |
  | `[:perplexed, :scrape, :attempt]`    | `duration` (ms), `cost`            | `url`, `tier`, `outcome`, `billable`      |
  | `[:perplexed, :searxng, :attempt]`   | `duration` (ms), `hits`            | `instance`, `outcome`, `retry_after_ms`   |
  | `[:perplexed, :searxng, :circuit]`   | `count` (always 1)                 | `instance`, `from`, `to`, `cooldown_ms`   |
  | `[:perplexed, :searxng, :instances]` | `count` (live instances)           | `result`                                  |
  | `[:perplexed, :provider, :alert]`    | `count` (always 1)                 | `provider`, `reason`, `status`, `message` |

  `result` is `:ok` or `:error`. On an alert, `status` and `message` are
  present when the provider answered with an HTTP error. `[:perplexed, :search,
  :attempt]` is emitted for each step of a fallback chain (a list of
  providers); a single provider emits just the span.

  An alert fires when a provider answers that credits or quota ran out
  (`:quota_exhausted`), that the credentials were rejected
  (`:authentication`), or that requests are being throttled
  (`:rate_limited`). A missing credential does not alert; unconfigured
  providers are expected.
  """

  @alert_reasons [:quota_exhausted, :authentication, :rate_limited]

  @doc "Emits `[:perplexed | event]` with `measurements` and `metadata`."
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements, metadata) when is_list(event),
    do: :telemetry.execute([:perplexed | event], measurements, metadata)

  @doc """
  Emits `[:perplexed, kind, :attempt]` for one step of a search chain or
  scrape ladder: `duration` (ms) and `cost`, with `metadata` plus
  `billable`, true when the step cost anything.
  """
  @spec attempt(atom(), non_neg_integer(), float(), map()) :: :ok
  def attempt(kind, duration_ms, cost, metadata) when is_atom(kind),
    do:
      emit(
        [kind, :attempt],
        %{duration: duration_ms, cost: cost},
        Map.put(metadata, :billable, cost > 0)
      )

  @doc """
  Runs `fun` as a `[:perplexed | event]` span. `fun` returns
  `{result, stop_measurements, stop_metadata}`; the span returns `result`.
  """
  @spec span([atom()], map(), (-> {result, map(), map()})) :: result when result: term()
  def span(event, metadata, fun) when is_list(event) and is_function(fun, 0) do
    :telemetry.span([:perplexed | event], metadata, fn ->
      {result, measurements, stop_metadata} = fun.()
      {result, measurements, Map.merge(metadata, stop_metadata)}
    end)
  end

  @doc "Emits a provider alert when `reason` is one that needs a person's attention."
  @spec maybe_alert(atom(), atom(), map()) :: :ok
  def maybe_alert(provider, reason, metadata) when reason in @alert_reasons do
    emit(
      [:provider, :alert],
      %{count: 1},
      Map.merge(%{provider: provider, reason: reason}, Map.take(metadata, [:status, :message]))
    )
  end

  def maybe_alert(_provider, _reason, _metadata), do: :ok
end
