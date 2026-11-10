defmodule Perplexed.Application do
  @moduledoc false
  # Starts the stateless task supervisor that searches and scrapes run under,
  # and the SearXNG pool and instance store, so they are available whether
  # or not the host has started `{Perplexed, settings}`.

  use Application

  alias Perplexed.Search.SearXNG.{Instances, Pool}
  alias Perplexed.TaskSupervisor

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [
        {Task.Supervisor, name: TaskSupervisor},
        Pool,
        Instances
      ],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
