defmodule Perplexed.HttpTest do
  # Attaches a global telemetry handler for provider alerts.
  use ExUnit.Case, async: false

  alias Perplexed.{Fixtures, Http}

  @url "https://api.example.test/v1/thing"

  def handle(_event, measurements, metadata, %{pid: pid}),
    do: send(pid, {:alert, measurements, metadata})

  setup context do
    provider = :"http_test_#{System.unique_integer([:positive])}"
    id = "http-test-#{inspect(context.test)}"

    :ok =
      :telemetry.attach(id, [:perplexed, :provider, :alert], &__MODULE__.handle/4, %{pid: self()})

    on_exit(fn -> :telemetry.detach(id) end)

    {:ok, provider: provider}
  end

  defp post(provider, plug, extra \\ []) do
    Http.post_json(provider, @url, %{"q" => 1}, "token",
      req_options: [plug: plug, retry_delay: 0, retry_log_level: false] ++ extra
    )
  end

  defp json(status, payload), do: Fixtures.json_plug(self(), status, payload)

  describe "post_json/5 status classification" do
    test "returns a 2xx response", %{provider: provider} do
      assert {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} =
               post(provider, json(200, %{"ok" => true}))
    end

    test "sends the body as JSON with a bearer token", %{provider: provider} do
      plug = fn conn ->
        send(self(), {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Fixtures.json_plug(self(), 200, %{}).(conn)
      end

      assert {:ok, _response} = post(provider, plug)
      assert_received {:auth, ["Bearer token"]}
      assert_received {:request, "/v1/thing", %{"q" => 1}}
    end

    for {status, reason} <- [
          {401, :authentication},
          {403, :authentication},
          {402, :quota_exhausted},
          {404, :not_found},
          {429, :rate_limited},
          {400, :invalid_response},
          {422, :invalid_response},
          {409, :invalid_response}
        ] do
      test "#{status} is #{reason}", %{provider: provider} do
        assert {:error, {unquote(reason), metadata}} =
                 post(provider, json(unquote(status), %{"error" => "details"}))

        assert metadata == %{
                 provider: provider,
                 url: @url,
                 status: unquote(status),
                 message: "details"
               }
      end
    end

    test "500 is upstream once retries are spent", %{provider: provider} do
      assert {:error, {:upstream, %{status: 500, provider: ^provider}}} =
               post(provider, json(500, %{"error" => "boom"}))
    end

    test "429 with a credits message is quota exhausted", %{provider: provider} do
      for message <- ["Insufficient credits", "Monthly quota reached", "Payment failed"] do
        assert {:error, {:quota_exhausted, %{status: 429}}} =
                 post(provider, json(429, %{"error" => message})),
               message
      end
    end

    test "429 that only says rate limit is throttling", %{provider: provider} do
      assert {:error, {:rate_limited, _metadata}} =
               post(provider, json(429, %{"error" => "Rate limit exceeded"}))
    end
  end

  describe "post_json/5 messages" do
    test "reads error.message", %{provider: provider} do
      assert {:error, {_reason, %{message: "nested"}}} =
               post(provider, json(400, %{"error" => %{"message" => "nested"}}))
    end

    test "reads an error string", %{provider: provider} do
      assert {:error, {_reason, %{message: "plain error"}}} =
               post(provider, json(400, %{"error" => "plain error"}))
    end

    test "reads message", %{provider: provider} do
      assert {:error, {_reason, %{message: "top message"}}} =
               post(provider, json(400, %{"message" => "top message"}))
    end

    test "reads the first of errors", %{provider: provider} do
      body = %{"errors" => [%{"message" => "first"}, %{"message" => "second"}]}
      assert {:error, {_reason, %{message: "first"}}} = post(provider, json(400, body))
    end

    test "uses a plain-text body as the message", %{provider: provider} do
      plug = Fixtures.plug(400, "gateway said no", [{"content-type", "text/plain"}])
      assert {:error, {_reason, %{message: "gateway said no"}}} = post(provider, plug)
    end

    test "has no message for an empty body or an unknown shape", %{provider: provider} do
      assert {:error, {_reason, %{message: nil}}} = post(provider, Fixtures.plug(400, ""))
      assert {:error, {_reason, %{message: nil}}} = post(provider, json(400, %{"other" => 1}))
    end

    test "bounds the message to 300 characters", %{provider: provider} do
      long = String.duplicate("x", 500)

      assert {:error, {_reason, %{message: message}}} =
               post(provider, json(400, %{"error" => long}))

      assert String.length(message) == 300
    end
  end

  describe "post_json/5 transport and retries" do
    test "a transport error carries provider, url and reason", %{provider: provider} do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, {:transport, metadata}} = post(provider, plug)
      assert metadata == %{provider: provider, url: @url, reason: :timeout}
    end

    test "a timeout is not sent again", %{provider: provider} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, {:transport, _metadata}} = post(provider, plug)
      assert Agent.get(calls, & &1) == 1
    end

    test "a closed connection is retried once", %{provider: provider} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))
        Req.Test.transport_error(conn, :closed)
      end

      assert {:error, {:transport, %{reason: :closed}}} = post(provider, plug)
      assert Agent.get(calls, & &1) == 2
    end

    test "a 500 then a 200 succeeds on the retry", %{provider: provider} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> Plug.Conn.send_resp(conn, 500, "")
          _ -> Fixtures.json_plug(self(), 200, %{"ok" => true}).(conn)
        end
      end

      assert {:ok, %Req.Response{status: 200}} = post(provider, plug)
      assert Agent.get(calls, & &1) == 2
      refute_received {:alert, _measurements, _metadata}
    end

    test "a 400 is not retried", %{provider: provider} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))
        Plug.Conn.send_resp(conn, 400, "")
      end

      assert {:error, {:invalid_response, _metadata}} = post(provider, plug)
      assert Agent.get(calls, & &1) == 1
    end
  end

  describe "provider alerts" do
    test "credential, credit and throttling failures alert", %{provider: provider} do
      for {status, reason} <- [
            {401, :authentication},
            {402, :quota_exhausted},
            {429, :rate_limited}
          ] do
        assert {:error, {^reason, _metadata}} = post(provider, json(status, %{"error" => "x"}))

        assert_received {:alert, %{count: 1},
                         %{provider: ^provider, reason: ^reason, status: ^status, message: "x"}}
      end
    end

    test "other failures do not alert", %{provider: provider} do
      for status <- [400, 404, 500] do
        assert {:error, _error} = post(provider, json(status, %{"error" => "x"}))
      end

      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end
      assert {:error, {:transport, _metadata}} = post(provider, plug)

      refute_received {:alert, _measurements, _metadata}
    end
  end

  describe "classify/3" do
    test "passes a successful response through" do
      response = %Req.Response{status: 204}
      assert Http.classify({:ok, response}, :p, @url) == {:ok, response}
    end

    test "keeps a non-timeout exception as the transport reason" do
      assert {:error, {:transport, %{reason: :oops}}} =
               Http.classify({:error, :oops}, :p, @url)
    end
  end

  describe "invalid_response/3" do
    test "reports the provider, url and the body's message" do
      assert Http.invalid_response(:p, @url, %{"message" => "odd shape"}) ==
               {:error, {:invalid_response, %{provider: :p, url: @url, message: "odd shape"}}}
    end

    test "has a nil message for a body without one" do
      assert {:error, {:invalid_response, %{message: nil}}} = Http.invalid_response(:p, @url, nil)
    end
  end
end
