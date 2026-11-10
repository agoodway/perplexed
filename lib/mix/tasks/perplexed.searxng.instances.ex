defmodule Mix.Tasks.Perplexed.Searxng.Instances do
  @shortdoc "Lists live public SearXNG instances from searx.space"
  @moduledoc """
  Fetches today's public SearXNG instances from searx.space, probes each
  start page from this machine, and prints which are up, fastest first.

      mix perplexed.searxng.instances
      mix perplexed.searxng.instances --country US --country CA --max-median 2500
      mix perplexed.searxng.instances --format elixir     # a config snippet
      mix perplexed.searxng.instances --format json --output instances.json
      mix perplexed.searxng.instances --no-probe          # searx.space only

  ## Options

    * `--country` - ISO code to keep, repeatable or comma-separated.
    * `--max-median` - slowest searx.space median search time (ms) to keep.
    * `--min-success` - lowest searx.space test-search success %, default 90.
    * `--no-probe` - skip checking the instances from here.
    * `--all` - also print instances that are down, walled or refusing
      (table only).
    * `--format` - `table` (default), `json` or `elixir`.
    * `--output` - write to this file instead of printing.
    * `--proxy` - probe through this proxy URL.

  The probe requests each start page once (never a search). A live start
  page does not promise searches will be answered, since SearXNG's limiter
  acts on `/search`; for hard-coding a list, prefer `searxng_instances:
  :auto`, which rediscovers daily (see `Perplexed.Search.SearXNG.Instances`).
  """

  use Mix.Task

  alias Perplexed.Search.SearXNG.Directory

  @switches [
    country: :keep,
    max_median: :integer,
    min_success: :integer,
    probe: :boolean,
    all: :boolean,
    format: :string,
    output: :string,
    proxy: :string
  ]

  @formats ~w(table json elixir)

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")
    listing(opts)
  end

  @doc false
  # The task's work for parsed `opts`; `request_options` (such as
  # `req_options: [plug: ...]`) go to every directory and probe request, so
  # tests need no network.
  @spec listing(keyword(), keyword()) :: :ok
  def listing(opts, request_options \\ []) do
    format = opts |> Keyword.get(:format, "table") |> known_format()

    opts
    |> directory_options()
    |> Keyword.merge(request_options)
    |> Directory.fetch()
    |> listed(Keyword.put(opts, :format, format), request_options)
  end

  # Checked before any request, so a typo costs no probing.
  defp known_format(format) when format in @formats, do: format

  defp known_format(format),
    do: Mix.raise("Unknown --format #{inspect(format)}; use #{Enum.join(@formats, ", ")}")

  defp listed({:ok, entries}, opts, request_options) do
    format = Keyword.fetch!(opts, :format)

    entries
    |> probed(Keyword.get(opts, :probe, true), opts, request_options)
    |> shown(Keyword.get(opts, :all, false), format)
    |> render(format)
    |> write(Keyword.get(opts, :output))
  end

  defp listed({:error, reason}, _opts, _request_options),
    do: Mix.raise("Could not fetch searx.space: #{inspect(reason)}")

  defp directory_options(opts) do
    [
      countries:
        opts
        |> Keyword.get_values(:country)
        |> Enum.flat_map(&String.split(&1, ",", trim: true))
        |> countries(),
      max_median_ms: Keyword.get(opts, :max_median)
    ]
    |> Keyword.merge(Keyword.take(opts, [:min_success]))
  end

  defp countries([]), do: nil
  defp countries(codes), do: codes

  # Progress goes to stderr so `--format json > file` stays valid JSON.
  defp probed(entries, true = _probe?, opts, request_options) do
    IO.puts(:stderr, "Probing #{length(entries)} instances...")
    Directory.probe(entries, [proxy: Keyword.get(opts, :proxy)] ++ request_options)
  end

  defp probed(entries, false = _probe?, _opts, _request_options), do: entries

  # Machine-readable output is the instances worth using; the table can show all.
  defp shown(entries, true = _all, "table"), do: entries
  defp shown(entries, _all, _format), do: Enum.filter(entries, &Directory.alive?/1)

  defp render(entries, "json"),
    do: entries |> Enum.map(&json_entry/1) |> Jason.encode_to_iodata!(pretty: true)

  defp render(entries, "elixir") do
    urls = Enum.map_join(entries, ",\n", &"    #{inspect(&1.url)}")

    "# #{length(entries)} live SearXNG instances, #{Date.utc_today()}\nconfig :perplexed, searxng_instances: [\n#{urls}\n  ]\n"
  end

  defp render(entries, "table") do
    rows = Enum.map(entries, &row/1)

    header =
      row(%{
        url: "INSTANCE",
        countries: ["WHERE"],
        median_ms: "MEDIAN",
        probe: %{status: "STATUS", latency_ms: "RTT"}
      })

    Enum.join([header | rows], "\n") <> "\n\n#{length(entries)} instances\n"
  end

  defp json_entry(%{probe: %{status: status} = probe} = entry),
    do: %{entry | probe: %{probe | status: to_string(status)}}

  defp json_entry(entry), do: Map.put(entry, :probe, nil)

  defp row(%{url: url, countries: countries, median_ms: median} = entry) do
    {status, rtt} = probe_columns(Map.get(entry, :probe))

    [
      url |> printable() |> String.pad_trailing(40),
      countries |> Enum.join(",") |> printable() |> String.pad_trailing(8),
      String.pad_leading(ms(median), 8),
      String.pad_trailing(" " <> to_string(status), 11),
      String.pad_leading(ms(rtt), 7)
    ]
    |> Enum.join(" ")
  end

  # Directory text printed to a terminal: no control characters, so an entry
  # cannot carry escape sequences.
  defp printable(text), do: String.replace(text, ~r/[\x00-\x1f\x7f]/, "")

  defp probe_columns(%{status: status, latency_ms: rtt}), do: {status, rtt}
  defp probe_columns(nil), do: {"-", nil}

  defp ms(nil), do: "-"
  defp ms(value) when is_integer(value), do: "#{value}ms"
  defp ms(label), do: label

  defp write(output, nil), do: Mix.shell().info(output)

  defp write(output, path) do
    File.write!(path, output)
    Mix.shell().info("Wrote #{path}")
  end
end
