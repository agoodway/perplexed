defmodule Perplexed.PipelineTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Answer, Document, Fixtures, Pipeline}
  alias Perplexed.Answer.{Candidate, Source}
  alias Perplexed.Fixtures.{PaidScraper, SearchProvider}
  alias Perplexed.Search.Hit

  @official "https://museum.example.org/visit"
  @guide "https://guide.example.com/museum-hours"
  @blog "https://blog.example.net/best-museums"
  @forum "https://forum.example.com/thread/42"
  @shop "https://shop.example.com/tickets"

  # Two queries; @official appears in both and must be considered once.
  defp search_reply do
    fn
      "museum hours" ->
        {:ok,
         [
           %Hit{url: @official, title: "Visit us", description: "Hours and admission"},
           %Hit{url: @blog, title: "Ten best museums", description: "Listicle"},
           %Hit{url: @shop, title: "Buy tickets", description: "Ticket shop"}
         ]}

      "museum opening times weekdays" ->
        {:ok,
         [
           %Hit{url: @official, title: "Visit us", description: "Hours and admission"},
           %Hit{url: @guide, title: "Museum hours guide", description: "Opening times"},
           %Hit{url: @forum, title: "Is it open Monday?", description: "Forum thread"}
         ]}
    end
  end

  # @official is unreadable, so the pipeline must backfill from the next candidate.
  defp scrape_reply do
    fn
      @official ->
        {:error, :blocked}

      url ->
        {:ok, %Document{markdown: "#{url}\n\n" <> Fixtures.readable_text(), final_url: url}, nil}
    end
  end

  defp fields(%Zoi.Types.Map{fields: fields}), do: Enum.map(fields, &elem(&1, 0))

  defp text(%ReqLLM.Message{content: [%{text: text}]}), do: text

  # Scores each listed result by its URL, so rankings follow the hits a test's
  # queries actually returned.
  @scores %{
    @official => {0.95, "Official site"},
    @blog => {0.2, "Listicle"},
    @shop => {0.1, "Shop"},
    @guide => {0.8, "Hours guide"},
    @forum => {0.6, "Forum answer"}
  }

  defp rankings(%ReqLLM.Context{messages: messages}) do
    %{content: [%{text: text}]} = List.last(messages)

    ~r/<result id="(\d+)">\nTitle: [^\n]*\nURL: (\S+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [id, url] ->
      {relevance, reason} = Map.fetch!(@scores, url)
      %{"id" => String.to_integer(id), "relevance" => relevance, "reason" => reason}
    end)
  end

  # Answers the plan and rank calls by schema; the summary call by `summary`.
  defp model(test_pid, summary) do
    fn "test:model", context, schema, _opts ->
      send(test_pid, {:object_call, fields(schema), context})

      case fields(schema) do
        [:queries] ->
          {:ok,
           Fixtures.object_response(%{
             "queries" => ["museum hours", "museum opening times weekdays"]
           })}

        [:rankings] ->
          {:ok, Fixtures.object_response(%{"rankings" => rankings(context)})}

        _caller_schema ->
          summary.(context)
      end
    end
  end

  defp text_model(test_pid) do
    fn "test:model", context, _opts ->
      send(test_pid, {:text_call, context})

      {:ok,
       Fixtures.text_response(context, "Open nine to five on weekdays [1], closed Mondays [2].")}
    end
  end

  # Stub hosts such as `museum.example.org` do not resolve, so every test
  # scrape passes the per-call allow-all URL validator.
  defp base_opts(test_pid, overrides \\ []) do
    [
      model: "test:model",
      provider: {SearchProvider, reply: search_reply()},
      scrape_options: [ladder: [{PaidScraper, reply: scrape_reply()}]],
      max_sources: 2,
      generate_object: model(test_pid, fn _context -> raise "no schema summary expected" end),
      generate_text: text_model(test_pid)
    ]
    |> Keyword.merge(overrides)
    |> Keyword.update!(
      :scrape_options,
      &Keyword.put_new(&1, :url_validator, {Fixtures, :allow_url, []})
    )
  end

  describe "run/2 with a text answer" do
    test "plans, searches, ranks, scrapes with backfill, and answers with sources" do
      assert {:ok, %Answer{} = answer} =
               Pipeline.run("When is the museum open?", base_opts(self()))

      assert answer.answer == "Open nine to five on weekdays [1], closed Mondays [2]."
      assert answer.queries == ["museum hours", "museum opening times weekdays"]

      assert [
               %Source{
                 number: 1,
                 url: @guide,
                 title: "Museum hours guide",
                 relevance: 0.8,
                 tier: PaidScraper,
                 cost: 0.01
               },
               %Source{number: 2, url: @forum, relevance: 0.6}
             ] = answer.sources

      assert answer.cited == [1, 2]
    end

    test "lists every unique hit with its relevance, reason and outcome" do
      assert {:ok, %Answer{considered: considered}} =
               Pipeline.run("When is the museum open?", base_opts(self()))

      by_url = Map.new(considered, &{&1.url, &1})
      assert map_size(by_url) == 5

      assert %Candidate{status: :unreadable, relevance: 0.95, scrape_error: scrape_error} =
               by_url[@official]

      assert scrape_error == {:unreadable, %{attempts: [{PaidScraper, :blocked}], cost: 0.0}}

      assert %Candidate{status: :used, reason: "Hours guide"} = by_url[@guide]
      assert %Candidate{status: :used} = by_url[@forum]
      assert %Candidate{status: :dropped, reason: "Listicle"} = by_url[@blog]
      assert %Candidate{status: :dropped} = by_url[@shop]
      assert by_url[@official].queries == ["museum hours", "museum opening times weekdays"]
    end

    test "shows the summarizer only the used sources, numbered" do
      assert {:ok, _answer} = Pipeline.run("When is the museum open?", base_opts(self()))
      assert_received {:text_call, %ReqLLM.Context{messages: messages}}

      prompt = messages |> List.last() |> then(fn %{content: [%{text: text}]} -> text end)
      assert prompt =~ ~s(<source id="1">\nTitle: Museum hours guide\nURL: #{@guide})
      assert prompt =~ ~s(<source id="2">)
      refute prompt =~ @blog
    end

    test "gives the summarizer the passages of a long page that match the question" do
      filler = Enum.map_join(1..400, "\n\n", &"Paragraph #{&1} covers general administration.")
      deep = "On weekdays the museum opens at nine and closes at five."

      reply = fn
        @official ->
          {:error, :blocked}

        url ->
          {:ok,
           %Document{markdown: "# Handbook\n\n#{filler}\n\n#{deep}\n\n#{filler}", final_url: url},
           nil}
      end

      opts =
        base_opts(self(),
          page_chars: 2_000,
          scrape_options: [ladder: [{PaidScraper, reply: reply}]]
        )

      assert {:ok, _answer} = Pipeline.run("When is the museum open on weekdays?", opts)
      assert_received {:text_call, %ReqLLM.Context{messages: messages}}
      %{content: [%{text: prompt}]} = List.last(messages)

      assert prompt =~ deep
    end

    test "two hits that land on the same page fill one source slot" do
      same_page = fn
        @official -> {:error, :blocked}
        @forum -> {:ok, %Document{markdown: Fixtures.readable_text(), final_url: @guide}, nil}
        url -> {:ok, %Document{markdown: Fixtures.readable_text(), final_url: url}, nil}
      end

      opts =
        base_opts(self(),
          max_sources: 3,
          scrape_options: [ladder: [{PaidScraper, reply: same_page}]]
        )

      assert {:ok, %Answer{sources: sources, considered: considered}} =
               Pipeline.run("When?", opts)

      assert Enum.map(sources, & &1.url) == [@guide]
      assert Enum.find(considered, &(&1.url == @forum)).status == :duplicate
    end

    test "marks page and search text as untrusted data in the prompts" do
      assert {:ok, _answer} = Pipeline.run("When is the museum open?", base_opts(self()))

      assert_received {:object_call, [:rankings],
                       %ReqLLM.Context{messages: [rank_system, rank_user]}}

      assert text(rank_system) =~ "not instructions"
      assert text(rank_user) =~ ~s(<result id="1">)

      assert_received {:text_call, %ReqLLM.Context{messages: [summary_system, summary_user]}}
      assert text(summary_system) =~ "not instructions"
      assert text(summary_user) =~ "</source>"
    end

    test "caller model options override the built-in defaults" do
      test_pid = self()

      capture = fn "test:model", context, opts ->
        send(test_pid, {:summary_opts, opts})
        {:ok, Fixtures.text_response(context, "Open [1].")}
      end

      opts = base_opts(self(), generate_text: capture, model_options: [max_tokens: 9_999])
      assert {:ok, _answer} = Pipeline.run("When?", opts)
      assert_received {:summary_opts, summary_opts}
      assert Keyword.get(summary_opts, :max_tokens) == 9_999
    end

    test "a paid page that came back unreadable still counts toward cost" do
      reply = fn
        @official -> {:ok, %Document{markdown: "Too short."}, nil}
        url -> {:ok, %Document{markdown: Fixtures.readable_text(), final_url: url}, nil}
      end

      opts = base_opts(self(), scrape_options: [ladder: [{PaidScraper, reply: reply}]])
      assert {:ok, %Answer{usage: usage}} = Pipeline.run("When?", opts)
      assert_in_delta usage.scrape_cost, 0.03, 1.0e-9
    end

    test "reports usage and cost per step" do
      assert {:ok, %Answer{usage: usage, trace: trace}} =
               Pipeline.run("When is the museum open?", base_opts(self()))

      assert usage.model_calls == 3
      assert usage.searches == 2
      assert usage.scrapes == 3
      assert usage.scrape_tiers == %{PaidScraper => 2, failed: 1}
      assert usage.search_cost == 0.008
      assert usage.scrape_cost == 0.02
      assert_in_delta usage.model_cost, 0.003 + 0.003 + 0.002, 1.0e-9
      assert_in_delta usage.total_cost, 0.008 + 0.008 + 0.02, 1.0e-9

      assert Enum.map(trace, & &1.kind) |> Enum.uniq() |> Enum.sort() == [
               :model,
               :scrape,
               :search
             ]
    end
  end

  describe "run/2 options" do
    test "explicit queries skip the planning call" do
      opts = base_opts(self(), queries: ["museum opening times weekdays"])

      assert {:ok, %Answer{queries: ["museum opening times weekdays"], usage: usage}} =
               Pipeline.run("When?", opts)

      assert usage.model_calls == 2
      refute_received {:object_call, [:queries], _context}
    end

    test "explicit queries are trimmed, de-duplicated and stripped of blanks" do
      opts =
        base_opts(self(),
          queries: ["  museum hours ", "museum hours", ""],
          provider: any_search([%Hit{url: @guide, title: "Guide"}])
        )

      assert {:ok, %Answer{queries: ["museum hours"]}} = Pipeline.run("When?", opts)
    end

    test "explicit queries that are all blank fall back to the question" do
      opts =
        base_opts(self(),
          queries: ["  ", ""],
          provider: any_search([%Hit{url: @guide, title: "Guide"}])
        )

      assert {:ok, %Answer{queries: ["When?"]}} = Pipeline.run("When?", opts)
    end

    test "min_relevance drops lower-ranked hits even under max_sources" do
      opts = base_opts(self(), max_sources: 5, min_relevance: 0.7)
      assert {:ok, %Answer{sources: sources}} = Pipeline.run("When?", opts)
      assert Enum.map(sources, & &1.url) == [@guide]
    end

    test "a schema returns a validated object instead of text" do
      schema = Zoi.object(%{hours: Zoi.string(), source_numbers: Zoi.array(Zoi.integer())})

      summary = fn _context ->
        {:ok, Fixtures.object_response(%{"hours" => "9-5", "source_numbers" => [1]})}
      end

      opts = base_opts(self(), schema: schema, generate_object: model(self(), summary))

      assert {:ok, %Answer{answer: %{"hours" => "9-5", "source_numbers" => [1]}, cited: []}} =
               Pipeline.run("When?", opts)
    end

    test "a summary that passes on retry counts both model calls" do
      schema = Zoi.object(%{hours: Zoi.string()})
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      summary = fn _context ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, Fixtures.object_response(%{"hours" => 9})}
          _ -> {:ok, Fixtures.object_response(%{"hours" => "9-5"})}
        end
      end

      opts = base_opts(self(), schema: schema, generate_object: model(self(), summary))

      assert {:ok, %Answer{answer: %{"hours" => "9-5"}, usage: usage}} =
               Pipeline.run("When?", opts)

      assert usage.model_calls == 4
    end

    test "recognizes grouped and ranged citations" do
      grouped = fn "test:model", context, _opts ->
        {:ok, Fixtures.text_response(context, "Open weekdays [1, 2], see also [1-2].")}
      end

      assert {:ok, %Answer{cited: [1, 2]}} =
               Pipeline.run("When?", base_opts(self(), generate_text: grouped))
    end

    test "a task supervisor that is not running is an error, not an exit" do
      assert {:error, {:not_started, %{supervisor: :no_such_supervisor}}} =
               Pipeline.run("When?", base_opts(self(), task_supervisor: :no_such_supervisor))
    end

    test "a schema mismatch is retried once, then reported" do
      schema = Zoi.object(%{hours: Zoi.string()})
      summary = fn _context -> {:ok, Fixtures.object_response(%{"hours" => 9})} end
      opts = base_opts(self(), schema: schema, generate_object: model(self(), summary))

      assert {:error, {:invalid_schema, %{reason: :structured_output, step: :summarize}}} =
               Pipeline.run("When?", opts)
    end
  end

  describe "run/2 failures" do
    test "no readable relevant source is an error that still lists what was considered" do
      opts = base_opts(self(), min_relevance: 0.99)

      assert {:error, {:no_sources, %{considered: considered}}} = Pipeline.run("When?", opts)
      assert length(considered) == 5
      assert Enum.all?(considered, &(&1.status == :dropped))
    end

    test "one failed search does not stop the others" do
      reply = fn
        "museum hours" -> {:error, {:upstream, %{}}}
        query -> search_reply().(query)
      end

      opts = base_opts(self(), provider: {SearchProvider, reply: reply})
      assert {:ok, %Answer{sources: [_ | _]}} = Pipeline.run("When?", opts)
    end

    test "every search failing is an error" do
      reply = fn _query -> {:error, {:quota_exhausted, %{}}} end
      opts = base_opts(self(), provider: {SearchProvider, reply: reply})

      assert {:error, {:search_failed, %{errors: [_, _]}}} = Pipeline.run("When?", opts)
    end

    test "rejects an empty question or a missing model" do
      assert {:error, {:invalid_request, %{reason: :empty_query}}} =
               Pipeline.run("", base_opts(self()))

      assert {:error, {:invalid_request, %{reason: :no_model}}} =
               Pipeline.run("When?", base_opts(self(), model: nil))
    end
  end

  describe "run/2 planning" do
    defp any_search(hits), do: {SearchProvider, reply: fn _query -> {:ok, hits} end}

    defp planned(queries, test_pid) do
      fn "test:model", context, schema, _opts ->
        case fields(schema) do
          [:queries] ->
            {:ok, Fixtures.object_response(%{"queries" => queries})}

          [:rankings] ->
            {:ok, Fixtures.object_response(%{"rankings" => rankings(context)})}
        end
        |> tap(fn _ -> send(test_pid, {:planned, fields(schema)}) end)
      end
    end

    test "falls back to the question when the model returns only blank queries" do
      opts =
        base_opts(self(),
          provider: any_search([%Hit{url: @guide, title: "Guide"}]),
          generate_object: planned(["", "   "], self())
        )

      assert {:ok, %Answer{queries: ["When is it open?"]}} =
               Pipeline.run("When is it open?", opts)
    end

    test "trims, de-duplicates and truncates planned queries to max_queries" do
      queries = [" first ", "first", "second", "third", "fourth"]

      opts =
        base_opts(self(),
          max_queries: 2,
          provider: any_search([%Hit{url: @guide, title: "Guide"}]),
          generate_object: planned(queries, self())
        )

      assert {:ok, %Answer{queries: ["first", "second"], usage: %{searches: 2}}} =
               Pipeline.run("When?", opts)
    end

    test "tells the planner how many queries it may write" do
      test_pid = self()

      generate = fn "test:model", context, schema, _opts ->
        case fields(schema) do
          [:queries] ->
            send(test_pid, {:plan_prompt, text(hd(context.messages))})
            {:ok, Fixtures.object_response(%{"queries" => ["q"]})}

          [:rankings] ->
            {:ok, Fixtures.object_response(%{"rankings" => rankings(context)})}
        end
      end

      opts =
        base_opts(self(),
          max_queries: 2,
          provider: any_search([%Hit{url: @guide, title: "Guide"}]),
          generate_object: generate
        )

      assert {:ok, _answer} = Pipeline.run("When?", opts)
      assert_received {:plan_prompt, prompt}
      assert prompt =~ "up to 2"
    end
  end

  describe "run/2 ranking" do
    defp ranked(rankings) do
      fn "test:model", _context, schema, _opts ->
        case fields(schema) do
          [:rankings] -> {:ok, Fixtures.object_response(%{"rankings" => rankings})}
        end
      end
    end

    defp readable_page(url),
      do: {:ok, %Document{markdown: Fixtures.readable_text(), final_url: url}, nil}

    defp ranking_opts(rankings, extra \\ []) do
      hits = [
        %Hit{url: @official, title: "Official"},
        %Hit{url: @guide, title: "Guide"},
        %Hit{url: @blog, title: "Blog"}
      ]

      base_opts(
        self(),
        Keyword.merge(
          [
            queries: ["q"],
            max_sources: 5,
            scrape_options: [ladder: [{PaidScraper, reply: &readable_page/1}]],
            provider: any_search(hits),
            generate_object: ranked(rankings)
          ],
          extra
        )
      )
    end

    test "a hit the model skipped is not ranked, and an unknown id is ignored" do
      rankings = [
        %{"id" => 1, "relevance" => 0.9, "reason" => "Official"},
        %{"id" => 3, "relevance" => 0.6, "reason" => "Blog"},
        %{"id" => 999, "relevance" => 1.0, "reason" => "Ghost"}
      ]

      assert {:ok, %Answer{considered: considered}} =
               Pipeline.run("When?", ranking_opts(rankings))

      assert length(considered) == 3
      by_url = Map.new(considered, &{&1.url, &1})
      assert %Candidate{status: :dropped, relevance: +0.0, reason: "Not ranked"} = by_url[@guide]
      assert %Candidate{status: :used, reason: "Official"} = by_url[@official]
      assert %Candidate{status: :used, reason: "Blog"} = by_url[@blog]
    end

    test "relevance is clamped to the 0 to 1 range" do
      rankings = [
        %{"id" => 1, "relevance" => 7, "reason" => "Too high"},
        %{"id" => 2, "relevance" => -2.5, "reason" => "Too low"},
        %{"id" => 3, "relevance" => 0.5, "reason" => "Edge"}
      ]

      assert {:ok, %Answer{considered: considered, sources: sources}} =
               Pipeline.run("When?", ranking_opts(rankings))

      by_url = Map.new(considered, &{&1.url, &1})
      assert by_url[@official].relevance === 1.0
      assert by_url[@guide].relevance === 0.0
      assert by_url[@guide].status == :dropped
      assert by_url[@blog].status == :used
      assert Enum.map(sources, & &1.relevance) == [1.0, 0.5]
    end

    test "sources are read best first" do
      rankings = [
        %{"id" => 1, "relevance" => 0.6, "reason" => "a"},
        %{"id" => 2, "relevance" => 0.9, "reason" => "b"},
        %{"id" => 3, "relevance" => 0.7, "reason" => "c"}
      ]

      assert {:ok, %Answer{sources: sources}} = Pipeline.run("When?", ranking_opts(rankings))
      assert Enum.map(sources, & &1.url) == [@guide, @blog, @official]
    end
  end

  describe "run/2 model errors" do
    defp failing(step) do
      fn "test:model", context, schema, _opts ->
        case {fields(schema), step} do
          {[:queries], :plan} -> {:error, :plan_down}
          {[:queries], _} -> {:ok, Fixtures.object_response(%{"queries" => ["q"]})}
          {[:rankings], :rank} -> {:error, :rank_down}
          {[:rankings], _} -> {:ok, Fixtures.object_response(%{"rankings" => rankings(context)})}
        end
      end
    end

    defp one_hit, do: any_search([%Hit{url: @guide, title: "Guide"}])

    test "a failed plan call is an llm_provider error" do
      opts = base_opts(self(), provider: one_hit(), generate_object: failing(:plan))

      assert {:error, {:llm_provider, %{step: :plan, reason: :plan_down}}} =
               Pipeline.run("When?", opts)
    end

    test "a failed rank call is an llm_provider error" do
      opts = base_opts(self(), provider: one_hit(), generate_object: failing(:rank))

      assert {:error, {:llm_provider, %{step: :rank, reason: :rank_down}}} =
               Pipeline.run("When?", opts)
    end

    test "a failed text summary is an llm_provider error" do
      down = fn "test:model", _context, _opts -> {:error, :summary_down} end
      opts = base_opts(self(), provider: one_hit(), generate_text: down)

      assert {:error, {:llm_provider, %{step: :summarize, reason: :summary_down}}} =
               Pipeline.run("When?", opts)
    end

    test "a failed structured summary is an llm_provider error" do
      schema = Zoi.object(%{hours: Zoi.string()})
      summary = fn _context -> {:error, :summary_down} end
      generate = model(self(), summary)

      opts =
        base_opts(self(),
          schema: schema,
          provider: any_search([%Hit{url: @guide, title: "Guide"}]),
          generate_object: generate
        )

      assert {:error, {:llm_provider, %{step: :summarize, reason: :summary_down}}} =
               Pipeline.run("When?", opts)
    end
  end

  describe "run/2 citations" do
    defp cited(text) do
      fn "test:model", context, _opts -> {:ok, Fixtures.text_response(context, text)} end
    end

    test "ignores citation numbers with no matching source" do
      opts = base_opts(self(), generate_text: cited("Open [1], closed [7], also [0] and [2-9]."))

      assert {:ok, %Answer{cited: [1, 2], sources: [_, _]}} = Pipeline.run("When?", opts)
    end

    test "an answer with no citations cites nothing" do
      opts = base_opts(self(), generate_text: cited("Open weekdays."))
      assert {:ok, %Answer{cited: []}} = Pipeline.run("When?", opts)
    end

    test "a huge range is not expanded" do
      opts = base_opts(self(), generate_text: cited("See [1-1000000]."))
      assert {:ok, %Answer{cited: [1]}} = Pipeline.run("When?", opts)
    end
  end
end
