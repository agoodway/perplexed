defmodule Mix.Tasks.Tidewave do
  @shortdoc "Serves the Tidewave MCP for this library (dev only)"
  @moduledoc """
  Starts the app and serves Tidewave's MCP at
  `http://localhost:<port>/tidewave/mcp` so a coding agent can evaluate code
  inside the running project. Tidewave ships only as a Phoenix plug, so this
  runs that plug under Bandit for a library with no endpoint.

      mix tidewave            # port 4000
      mix tidewave --port 4123

  Lives in `dev/`, compiled only in `:dev` and left out of the Hex package.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer])
    port = Keyword.get(opts, :port, 4000)

    Mix.Task.run("app.start")
    {:ok, _pid} = Bandit.start_link(plug: Tidewave, port: port, ip: :loopback)
    Mix.shell().info("Tidewave MCP at http://localhost:#{port}/tidewave/mcp")
    Process.sleep(:infinity)
  end
end
