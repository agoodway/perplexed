defmodule Perplexed.Application do
  @moduledoc false
  # Starts the stateless task supervisor that searches and scrapes run under,
  # so it is available whether or not the host has started `{Perplexed, settings}`.

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Task.Supervisor, name: Perplexed.TaskSupervisor}],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
