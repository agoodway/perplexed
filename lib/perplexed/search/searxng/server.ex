defmodule Perplexed.Search.SearXNG.Server do
  @moduledoc false
  # What the SearXNG processes (`Pool`, `Instances`) share: each is
  # registered under `:name` (default its module) and keeps its state in a
  # protected ETS table that readers reach without calling the process,
  # through a `:persistent_term` keyed by module and name.

  @doc "Starts `module` registered under `opts[:name]`, default `module`."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) do
    name = Keyword.get(opts, :name, module)
    GenServer.start_link(module, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Creates the calling process's table for `{module, name}` and publishes it."
  @spec open_table(module(), GenServer.name()) :: :ets.tid()
  def open_table(module, name) do
    table = :ets.new(module, [:set, :protected, read_concurrency: true])
    :persistent_term.put({module, name}, table)
    table
  end

  @doc "The table published for `{module, name}`."
  @spec table(module(), GenServer.name()) :: :ets.tid()
  def table(module, name), do: :persistent_term.get({module, name})

  @doc "Withdraws the table published for `{module, name}`."
  @spec close_table(module(), GenServer.name()) :: boolean()
  def close_table(module, name), do: :persistent_term.erase({module, name})
end
