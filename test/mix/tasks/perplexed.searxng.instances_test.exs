defmodule Mix.Tasks.Perplexed.Searxng.InstancesTest do
  # Swaps the Mix shell, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [capture_io: 2]

  alias Mix.Tasks.Perplexed.Searxng.Instances, as: InstancesTask
  alias Perplexed.Fixtures

  @start_page ~s(<html><head><meta name="generator" content="searxng/2026.11.9"></head></html>)

  defp instance(median) do
    %{
      "network_type" => "normal",
      "http" => %{"status_code" => 200},
      "timing" => %{"search" => %{"success_percentage" => 100.0, "all" => %{"median" => median}}},
      "network" => %{"ips" => %{"192.0.2.1" => %{"asn_cidr" => "192.0.2.0/24"}}}
    }
  end

  defp network do
    Fixtures.router(self(), %{
      "searx.space" => fn conn ->
        Req.Test.json(conn, %{
          "instances" => %{
            "https://alive.test/" => instance(0.4),
            "https://down.test/" => instance(0.2)
          },
          "cidrs" => %{"192.0.2.0/24" => %{"network_country" => "US"}}
        })
      end,
      "alive.test" => &Plug.Conn.send_resp(&1, 200, @start_page),
      "down.test" => &Plug.Conn.send_resp(&1, 502, "")
    })
  end

  defp requests, do: [url_validator: {Fixtures, :allow_url, []}, req_options: [plug: network()]]

  # Runs the task with parsed `opts`, returning what it printed; probe
  # progress goes to stderr and is dropped.
  defp listing(opts) do
    capture_io(:stderr, fn -> InstancesTask.listing(opts, requests()) end)
    collect_output([])
  end

  defp collect_output(acc) do
    receive do
      {:mix_shell, :info, [text]} -> collect_output([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "the table lists live instances; --all adds the rest" do
    output = listing([])
    assert output =~ "https://alive.test/"
    refute output =~ "https://down.test/"
    assert output =~ "1 instances"

    all = listing(all: true)
    assert all =~ "https://down.test/"
    assert all =~ "down"
  end

  test "--format json prints only JSON, with the probe status as a string" do
    assert [%{"url" => "https://alive.test/", "probe" => %{"status" => "alive"}}] =
             [format: "json"] |> listing() |> Jason.decode!()
  end

  test "--format elixir prints a config snippet that parses" do
    snippet = listing(format: "elixir")
    assert snippet =~ ~s(searxng_instances: [\n    "https://alive.test/")
    assert {:ok, _quoted} = Code.string_to_quoted(snippet)
  end

  test "--no-probe lists every instance from the directory" do
    assert [_, _] = [format: "json", probe: false] |> listing() |> Jason.decode!()
  end

  test "--output writes the file" do
    path = Path.join(System.tmp_dir!(), "instances-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert listing(format: "json", output: path) =~ "Wrote #{path}"
    assert [%{"url" => "https://alive.test/"}] = path |> File.read!() |> Jason.decode!()
  end

  test "an unknown --format fails before any request" do
    assert_raise Mix.Error, ~r/Unknown --format "yaml"/, fn ->
      InstancesTask.listing([format: "yaml"], requests())
    end

    refute_received {:request, _host, _path, _params}
  end
end
