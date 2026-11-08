defmodule Perplexed.SearchTest do
  # Mutates `config :perplexed` credentials and attaches telemetry handlers.
  use ExUnit.Case, async: false

  alias Perplexed.{Document, Fixtures, Search}
  alias Perplexed.Fixtures.{PaidScraper, SearchProvider}
  alias Perplexed.Search.{Hit, Result}

  setup do
    restore =
      Fixtures.put_config(
        cloudflare_account_id: "acct",
        cloudflare_api_token: "token",
        deepseek_api_key: "ds-key",
        firecrawl_api_key: "fc-key",
        url_validator: {Fixtures, :allow_url, []}
      )

    on_exit(restore)
  end

  describe "run/3 Cloudflare providers" do
    test "searches Ceramic through AI Gateway and prices the call" do
      payload = %{
        "success" => true,
        "result" => %{
          "items" => [
            %{
              "url" => "https://example.org/museum",
              "title" => "Museum",
              "description" => "Hours"
            }
          ]
        }
      }

      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok, %Result{provider: :ceramic, cost: 0.00025, hits: [%Hit{} = hit]}} =
               Search.run(:ceramic, "museum opening hours", req_options: [plug: plug])

      assert hit.url == "https://example.org/museum"
      assert hit.provider == :ceramic

      assert_received {:request, "/client/v4/accounts/acct/ai/websearch/",
                       %{
                         "provider" => "ceramic",
                         "limit" => 8,
                         "options" => %{"gateway" => %{"id" => _}}
                       }}
    end

    test "routes Linkup and Exa through the same endpoint" do
      plug = Fixtures.json_plug(self(), 200, %{"result" => %{"items" => []}})

      assert {:ok, %Result{provider: :linkup}} =
               Search.run(:linkup, "q", req_options: [plug: plug])

      assert_received {:request, _path, %{"provider" => "linkup"}}

      assert {:ok, %Result{provider: :cloudflare_exa}} =
               Search.run(:cloudflare_exa, "q", req_options: [plug: plug])

      assert_received {:request, _path, %{"provider" => "exa"}}
    end

    test "an empty result costs the list price" do
      plug = Fixtures.json_plug(self(), 200, %{"result" => %{"items" => []}})

      assert {:ok, %Result{hits: [], cost: cost, total_cost: total}} =
               Search.run(:ceramic, "q", req_options: [plug: plug])

      assert cost == 0.00025
      assert total == 0.00025
    end

    test "an empty DeepSeek result is free" do
      plug = Fixtures.json_plug(self(), 200, %{"results" => []})

      assert {:ok, %Result{hits: [], cost: cost, total_cost: total}} =
               Search.run(:deepseek, "q", req_options: [plug: plug])

      assert cost == 0.0
      assert total == 0.0
    end

    test "a per-call gateway id is sent to Cloudflare" do
      plug = Fixtures.json_plug(self(), 200, %{"result" => %{"items" => []}})

      assert {:ok, _result} =
               Search.run(:ceramic, "q",
                 cloudflare_gateway_id: "my-gateway",
                 req_options: [plug: plug]
               )

      assert_received {:request, _path, %{"options" => %{"gateway" => %{"id" => "my-gateway"}}}}
    end
  end

  describe "run/3 malformed and unknown input" do
    test "skips Cloudflare items without a URL instead of crashing" do
      payload = %{
        "result" => %{"items" => [%{"title" => "No URL"}, %{"url" => "https://ok.test/"}]}
      }

      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok, %Result{hits: [%Hit{url: "https://ok.test/"}]}} =
               Search.run(:ceramic, "q", req_options: [plug: plug])
    end

    test "skips DeepSeek results without a URL" do
      plug =
        Fixtures.json_plug(self(), 200, %{
          "results" => [%{"title" => "x"}, %{"url" => "https://ok.test/"}]
        })

      assert {:ok, %Result{hits: [%Hit{url: "https://ok.test/"}]}} =
               Search.run(:deepseek, "q", req_options: [plug: plug])
    end

    test "an unknown Cloudflare upstream is an error, not a crash" do
      assert {:error, {:invalid_request, %{reason: {:unknown_upstream, "nope"}}}} =
               Search.run({Perplexed.Search.Cloudflare, provider: "nope"}, "q")
    end
  end

  describe "price/1" do
    test "prices a module spec by the upstream it names" do
      assert Search.price({Perplexed.Search.Cloudflare, provider: "exa"}) == 0.007
      assert Search.price(:cloudflare_exa) == 0.007
      assert Search.price(:ceramic) == 0.00025
    end
  end

  describe "retries" do
    test "a timed-out paid request is not sent again" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :attempt)
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, {:transport, %{reason: :timeout}}} =
               Search.run(:firecrawl, "q", req_options: [plug: plug, retry_delay: 0])

      assert_received :attempt
      refute_received :attempt
    end

    test "a refused connection is retried once" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :attempt)
        Req.Test.transport_error(conn, :econnrefused)
      end

      assert {:error, {:transport, _metadata}} =
               Search.run(:firecrawl, "q", req_options: [plug: plug, retry_delay: 0])

      assert_received :attempt
      assert_received :attempt
    end
  end

  describe "run/3 DeepSeek" do
    test "uses the model summary as the description and keeps page content" do
      payload = %{
        "results" => [
          %{
            "url" => "https://docs.example.org/museum",
            "title" => "Code",
            "summary" => "Long summary",
            "content" => "Full text",
            "date" => "2026-01-01T00:00:00+00:00"
          }
        ]
      }

      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok,
              %Result{
                cost: 0.00075,
                hits: [%Hit{description: "Long summary", content: "Full text"}]
              }} =
               Search.run(:deepseek, "museum opening hours", req_options: [plug: plug])

      assert_received {:request, "/v1/tools/search", %{"need_content" => true, "count" => 8}}
    end

    test "a missing key is an authentication error" do
      restore = Fixtures.put_config(deepseek_api_key: nil)
      on_exit(restore)

      assert {:error, {:authentication, %{reason: {:missing, :deepseek_api_key}}}} =
               Search.run(:deepseek, "q")
    end
  end

  describe "run/3 Firecrawl" do
    test "reads web hits" do
      payload = %{
        "success" => true,
        "data" => %{"web" => [%{"url" => "https://x.test/", "title" => "X"}]}
      }

      plug = Fixtures.json_plug(self(), 200, payload)

      assert {:ok,
              %Result{cost: 0.00198, hits: [%Hit{url: "https://x.test/", provider: :firecrawl}]}} =
               Search.run(:firecrawl, "q", req_options: [plug: plug])
    end
  end

  describe "provider alerts" do
    setup do
      test_pid = self()
      id = "perplexed-alert-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:perplexed, :provider, :alert],
        fn _event, _m, metadata, _ ->
          send(test_pid, {:alert, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "exhausted credits return quota_exhausted and alert" do
      plug = Fixtures.json_plug(self(), 402, %{"error" => "Insufficient credits"})

      assert {:error, {:quota_exhausted, %{status: 402}}} =
               Search.run(:firecrawl, "q", req_options: [plug: plug])

      assert_received {:alert, %{provider: :firecrawl, reason: :quota_exhausted, status: 402}}
    end

    test "a 429 that names credits is quota, not throttling" do
      plug =
        Fixtures.json_plug(self(), 429, %{"error" => %{"message" => "Credit balance exceeded"}})

      assert {:error, {:quota_exhausted, _metadata}} =
               Search.run(:deepseek, "q", req_options: [plug: plug])

      assert_received {:alert, %{reason: :quota_exhausted}}
    end

    test "a 429 rate limit is throttling, not exhausted credits" do
      plug =
        Fixtures.json_plug(self(), 429, %{"errors" => [%{"message" => "Rate limit exceeded"}]})

      assert {:error, {:rate_limited, %{status: 429}}} =
               Search.run(:ceramic, "q", req_options: [plug: plug])

      assert_received {:alert, %{reason: :rate_limited}}
    end

    test "a missing key does not alert" do
      restore = Fixtures.put_config(firecrawl_api_key: nil)
      on_exit(restore)

      assert {:error, {:authentication, _metadata}} = Search.run(:firecrawl, "q")
      refute_received {:alert, _metadata}
    end
  end

  describe "run/3 input errors" do
    test "an unknown provider name is an error, not a crash" do
      assert Search.run(:no_such_provider, "q") ==
               {:error, {:invalid_request, %{reason: {:unknown_provider, :no_such_provider}}}}
    end

    test "per-call credentials take precedence over settings" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => []}))
      end

      assert {:ok, _result} =
               Search.run(:deepseek, "q",
                 credentials: [deepseek_api_key: "per-call"],
                 req_options: [plug: plug]
               )

      assert_received {:auth, ["Bearer per-call"]}
    end

    test "a long provider error message is bounded" do
      plug =
        Fixtures.json_plug(self(), 500, %{"error" => %{"message" => String.duplicate("x", 5_000)}})

      assert {:error, {:upstream, %{message: message}}} =
               Search.run(:deepseek, "q", req_options: [plug: plug, retry: false])

      assert String.length(message) <= 300
    end
  end

  describe "Perplexed.search/2 scrape cost" do
    test "a paid scrape that came back unreadable still counts toward scrape_cost" do
      reply = fn _query -> {:ok, [%Hit{url: "https://thin.test/"}]} end
      thin = fn _url -> {:ok, %Document{markdown: "Too short."}, nil} end

      assert {:ok, %Result{scrape_cost: scrape_cost}} =
               Perplexed.search("q",
                 provider: {SearchProvider, reply: reply},
                 scrape: true,
                 scrape_options: [ladder: [{PaidScraper, reply: thin}]]
               )

      assert_in_delta scrape_cost, 0.01, 1.0e-9
    end
  end

  describe "custom providers" do
    test "a provider module is used directly and priced by its price/1" do
      reply = fn query -> {:ok, [%Hit{url: "https://#{query}.test/", provider: :custom}]} end

      assert {:ok, %Result{cost: 0.004, hits: [%Hit{url: "https://museum.test/"}]}} =
               Search.run({SearchProvider, reply: reply}, "museum")
    end
  end

  describe "Perplexed.search/2 with scrape: true" do
    test "attaches each hit's document and adds scrape cost to the total" do
      reply = fn _query -> {:ok, [%Hit{url: "https://a.test/"}, %Hit{url: "https://b.test/"}]} end

      scrape_reply = fn
        "https://a.test/" -> {:ok, %Document{markdown: Fixtures.readable_text()}, nil}
        _other -> {:error, :blocked}
      end

      assert {:ok, %Result{hits: [first, second]} = result} =
               Perplexed.search("museum",
                 provider: {SearchProvider, reply: reply},
                 scrape: true,
                 scrape_options: [ladder: [{PaidScraper, reply: scrape_reply}]]
               )

      assert %Document{tier: PaidScraper} = first.document
      assert second.document == nil

      assert second.scrape_error ==
               {:unreadable, %{attempts: [{PaidScraper, :blocked}], cost: 0.0}}

      assert_in_delta result.scrape_cost, 0.01, 1.0e-9
      assert_in_delta result.total_cost, 0.014, 1.0e-9
    end
  end
end
