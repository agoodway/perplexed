defmodule Perplexed.DeepSeekFirecrawlTest do
  # DeepSeek and Firecrawl alone and in either order, for search, page
  # fetching and answers, behind one stub network that routes by API host.
  # Mutates `config :perplexed` credentials.
  use ExUnit.Case, async: false

  alias Perplexed.{Answer, Document, Fixtures, Pipeline, Scrape, Search}
  alias Perplexed.Answer.Source
  alias Perplexed.Scraper.Firecrawl
  alias Perplexed.Search.{Hit, Result}
  alias ReqLLM.Context

  @page "https://museum.example.org/visit"
  @other "https://guide.example.com/hours"

  setup do
    on_exit(
      Fixtures.put_config(
        deepseek_api_key: "ds-key",
        firecrawl_api_key: "fc-key",
        url_validator: {Fixtures, :allow_url, []}
      )
    )
  end

  # `replies` maps {host, path} to a function of the decoded request body
  # returning `{status, json}`; every request is reported to the test.
  defp network(test_pid, replies) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:api, conn.host, conn.request_path, request})

      {status, json} =
        case Map.fetch(replies, {conn.host, conn.request_path}) do
          {:ok, reply} -> reply.(request)
          :error -> {404, %{"error" => "no stub"}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(json))
    end
  end

  defp readable, do: "# Visiting\n\n" <> Fixtures.readable_text()

  defp deepseek_results(content \\ ""),
    do: fn _body ->
      {200,
       %{
         "results" => [
           %{
             "url" => @page,
             "title" => "Visit",
             "summary" => "Hours and admission",
             "content" => content,
             "rerank_score" => 2.2,
             "authority" => 4,
             "site_name" => "Museum"
           }
         ]
       }}
    end

  defp deepseek_empty, do: fn _body -> {200, %{"results" => []}} end

  defp deepseek_broke,
    do: fn _body -> {402, %{"error" => %{"message" => "Insufficient Balance"}}} end

  defp firecrawl_results,
    do: fn _body ->
      {200,
       %{
         "success" => true,
         "data" => %{"web" => [%{"url" => @other, "title" => "Hours", "description" => "Guide"}]}
       }}
    end

  defp firecrawl_down, do: fn _body -> {500, %{"success" => false, "error" => "upstream"}} end

  defp deepseek_page, do: fn _body -> {200, %{"title" => "Visit", "content" => readable()}} end

  defp deepseek_no_page,
    do: fn _body -> {404, %{"error" => %{"message" => "no usable content"}}} end

  defp firecrawl_page,
    do: fn _body -> {200, %{"success" => true, "data" => %{"markdown" => readable()}}} end

  @ds_search {"api.deepseek.com", "/v1/tools/search"}
  @ds_fetch {"api.deepseek.com", "/v1/tools/fetch"}
  @fc_search {"api.firecrawl.dev", "/v2/search"}
  @fc_scrape {"api.firecrawl.dev", "/v2/scrape"}

  describe "search" do
    test "each provider alone" do
      plug =
        network(self(), %{@ds_search => deepseek_results(), @fc_search => firecrawl_results()})

      assert {:ok, %Result{provider: :deepseek, hits: [%Hit{url: @page}]}} =
               Search.run(:deepseek, "museum hours", req_options: [plug: plug, retry: false])

      assert {:ok, %Result{provider: :firecrawl, hits: [%Hit{url: @other}]}} =
               Search.run(:firecrawl, "museum hours", req_options: [plug: plug, retry: false])
    end

    test "DeepSeek first, Firecrawl when DeepSeek is out of balance" do
      plug = network(self(), %{@ds_search => deepseek_broke(), @fc_search => firecrawl_results()})

      assert {:ok, %Result{provider: :firecrawl, attempts: [ds, fc], cost: 0.00198}} =
               Search.run([:deepseek, :firecrawl], "museum hours",
                 req_options: [plug: plug, retry: false]
               )

      assert %{provider: :deepseek, outcome: {:error, {:quota_exhausted, _}}} = ds
      assert %{provider: :firecrawl, outcome: :ok} = fc
    end

    test "DeepSeek first, Firecrawl when DeepSeek finds nothing (and the empty search is free)" do
      plug = network(self(), %{@ds_search => deepseek_empty(), @fc_search => firecrawl_results()})

      assert {:ok, %Result{provider: :firecrawl, attempts: [%{outcome: :empty, cost: +0.0}, _]}} =
               Search.run([:deepseek, :firecrawl], "museum hours",
                 req_options: [plug: plug, retry: false]
               )
    end

    test "Firecrawl first, DeepSeek when Firecrawl fails" do
      plug = network(self(), %{@ds_search => deepseek_results(), @fc_search => firecrawl_down()})

      assert {:ok,
              %Result{
                provider: :deepseek,
                attempts: [%{provider: :firecrawl, outcome: {:error, _}}, _]
              }} =
               Search.run([:firecrawl, :deepseek], "museum hours",
                 req_options: [plug: plug, retry: false]
               )
    end

    test "stops at the first that answers" do
      plug =
        network(self(), %{@ds_search => deepseek_results(), @fc_search => firecrawl_results()})

      assert {:ok, %Result{provider: :deepseek}} =
               Search.run([:deepseek, :firecrawl], "museum hours",
                 req_options: [plug: plug, retry: false]
               )

      refute_received {:api, "api.firecrawl.dev", _path, _body}
    end
  end

  describe "page fetching" do
    test "each fetcher alone" do
      plug = network(self(), %{@ds_fetch => deepseek_page(), @fc_scrape => firecrawl_page()})

      assert {:ok, %Document{tier: :deepseek, cost: 0.00075}} =
               Scrape.run(@page, ladder: [:deepseek], req_options: [plug: plug, retry: false])

      assert {:ok, %Document{tier: :firecrawl, cost: 0.00099}} =
               Scrape.run(@page, ladder: [:firecrawl], req_options: [plug: plug, retry: false])
    end

    test "DeepSeek first, Firecrawl when DeepSeek has no usable content" do
      plug = network(self(), %{@ds_fetch => deepseek_no_page(), @fc_scrape => firecrawl_page()})

      assert {:ok,
              %Document{
                tier: :firecrawl,
                attempts: [deepseek: :no_content, firecrawl: :ok],
                cost: 0.00099
              }} =
               Scrape.run(@page,
                 ladder: [:deepseek, :firecrawl],
                 req_options: [plug: plug, retry: false]
               )
    end

    test "Firecrawl first, DeepSeek when Firecrawl fails" do
      plug = network(self(), %{@ds_fetch => deepseek_page(), @fc_scrape => firecrawl_down()})

      assert {:ok, %Document{tier: :deepseek, attempts: [firecrawl: :upstream, deepseek: :ok]}} =
               Scrape.run(@page,
                 ladder: [:firecrawl, :deepseek],
                 req_options: [plug: plug, retry: false]
               )
    end

    test "a thin DeepSeek page moves on to Firecrawl, and still counts what it cost" do
      thin = fn _body -> {200, %{"content" => "Hours."}} end
      plug = network(self(), %{@ds_fetch => thin, @fc_scrape => firecrawl_page()})

      assert {:ok, %Document{attempts: [deepseek: :thin, firecrawl: :ok], cost: cost}} =
               Scrape.run(@page,
                 ladder: [:deepseek, :firecrawl],
                 req_options: [plug: plug, retry: false]
               )

      assert_in_delta cost, 0.00075 + 0.00099, 1.0e-9
    end

    test "with both keys the default ladder is free tiers, then DeepSeek, then Firecrawl" do
      assert Scrape.default_ladder() == [:direct, :impersonated, :deepseek, :firecrawl]
    end
  end

  describe "Firecrawl pricing" do
    test "firecrawl_credit_usd prices Firecrawl searches (2 credits) and pages (1 credit)" do
      Fixtures.put_config(firecrawl_credit_usd: 0.0038)
      plug = network(self(), %{@fc_search => firecrawl_results(), @fc_scrape => firecrawl_page()})

      assert {:ok, %Result{cost: search_cost}} =
               Search.run(:firecrawl, "museum hours", req_options: [plug: plug, retry: false])

      assert_in_delta search_cost, 0.0076, 1.0e-9

      assert {:ok, %Document{cost: page_cost}} =
               Scrape.run(@page, ladder: [:firecrawl], req_options: [plug: plug, retry: false])

      assert_in_delta page_cost, 0.0038, 1.0e-9
    end

    test "defaults to the Standard plan rate" do
      Fixtures.put_config(firecrawl_credit_usd: nil)
      assert Firecrawl.credit_usd() == 0.00099
    end
  end

  describe "answers" do
    defp model(test_pid) do
      [
        generate_object: fn "test:model", context, schema, _opts ->
          send(test_pid, {:object_call, context})

          case schema do
            %Zoi.Types.Map{fields: [{:queries, _} | _]} ->
              {:ok, Fixtures.object_response(%{"queries" => ["museum hours"]})}

            %Zoi.Types.Map{fields: [{:rankings, _} | _]} ->
              {:ok,
               Fixtures.object_response(%{
                 "rankings" => [
                   %{"id" => 1, "relevance" => 0.9, "reason" => "Official"},
                   %{"id" => 2, "relevance" => 0.8, "reason" => "Guide"}
                 ]
               })}
          end
        end,
        generate_text: fn "test:model", context, _opts ->
          {:ok, Fixtures.text_response(context, "Open nine to five [1].")}
        end
      ]
    end

    test "DeepSeek search page text is read as is; a Firecrawl hit is fetched cheapest first" do
      plug =
        network(self(), %{
          # DeepSeek answers the first query and finds nothing for the second,
          # which falls through to Firecrawl.
          @ds_search => fn
            %{"query" => "museum hours"} = body -> deepseek_results(readable()).(body)
            body -> deepseek_empty().(body)
          end,
          @fc_search => firecrawl_results(),
          @ds_fetch => deepseek_no_page(),
          @fc_scrape => firecrawl_page()
        })

      # Two explicit queries skip the planning call; each runs down the chain.
      opts =
        model(self()) ++
          [
            model: "test:model",
            queries: ["museum hours", "museum opening times"],
            provider: [:deepseek, :firecrawl],
            search_options: [req_options: [plug: plug, retry: false]],
            scrape_options: [
              ladder: [:deepseek, :firecrawl],
              req_options: [plug: plug, retry: false],
              url_validator: {Fixtures, :allow_url, []}
            ],
            max_sources: 2
          ]

      assert {:ok, %Answer{sources: sources}} = Pipeline.run("When is the museum open?", opts)
      assert [%Source{url: @page, tier: :search}] = Enum.filter(sources, &(&1.url == @page))

      # The DeepSeek page came with its text, so it was never fetched.
      refute_received {:api, "api.deepseek.com", "/v1/tools/fetch", %{"url" => @page}}

      # The Firecrawl hit had no text: DeepSeek Fetch first, then Firecrawl.
      assert_received {:api, "api.deepseek.com", "/v1/tools/fetch", %{"url" => @other}}
      assert_received {:api, "api.firecrawl.dev", "/v2/scrape", %{"url" => @other}}
      assert [%Source{tier: :firecrawl}] = Enum.filter(sources, &(&1.url == @other))
    end

    test "shows the ranker DeepSeek's score and authority" do
      plug = network(self(), %{@ds_search => deepseek_results(readable())})

      opts =
        model(self()) ++
          [
            model: "test:model",
            queries: ["museum hours"],
            provider: :deepseek,
            search_options: [req_options: [plug: plug, retry: false]],
            max_sources: 1
          ]

      assert {:ok, _answer} = Pipeline.run("When is the museum open?", opts)
      assert_received {:object_call, %Context{messages: messages}}
      %{content: [%{text: prompt}]} = List.last(messages)
      assert prompt =~ "provider relevance 2.2 of 3"
      assert prompt =~ "authority 4 of 4"
    end
  end
end
