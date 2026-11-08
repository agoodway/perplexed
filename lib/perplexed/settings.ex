defmodule Perplexed.Settings do
  @moduledoc false
  # Owns Perplexed's settings while the host runs it: stores them in
  # `:persistent_term` on start and erases them on stop, so a stopped
  # Perplexed leaves nothing behind. There is one instance per node.
  #
  # The settings arrive as a zero-arity function and are not kept in the
  # process state, so neither the child spec, `:sys.get_state/1`, nor an OTP
  # crash report prints the API keys they carry.

  use GenServer

  alias Perplexed.Config

  @doc "Starts the settings owner with a function returning the settings."
  @spec start_link((-> keyword())) :: GenServer.on_start()
  def start_link(settings) when is_function(settings, 0),
    do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl true
  def init(settings) do
    Process.flag(:trap_exit, true)
    Config.put(settings.())
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, nil), do: Config.erase()
end
