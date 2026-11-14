defmodule Perplexed.ScrapeTest do
  # Mutates `config :perplexed` (URL validator, PDF converter, credentials).
  use ExUnit.Case, async: false

  alias Perplexed.{Document, Fixtures, Scrape}
  alias Perplexed.Fixtures.{BlockedOnlyScraper, PaidScraper, Scraper}

  @url "http://93.184.215.14/guide"

  setup do
    restore =
      Fixtures.put_config(
        url_validator: {Fixtures, :allow_url, []},
        pdf_converter: Fixtures.PdfConverter,
        cloudflare_account_id: "acct",
        cloudflare_api_token: "token"
      )

    on_exit(restore)
  end

  defp ok_reply(markdown \\ Fixtures.readable_text()),
    do: fn _url -> {:ok, %Document{markdown: markdown, content_type: "text/markdown"}, nil} end

  describe "run/2 direct tier" do
    test "converts readable HTML to Markdown at no cost" do
      plug =
        Fixtures.plug(200, Fixtures.readable_html(), [
          {"content-type", "text/html; charset=utf-8"}
        ])

      assert {:ok, %Document{} = document} =
               Scrape.run(@url, ladder: [:direct], req_options: [plug: plug])

      assert document.tier == :direct
      assert document.markdown =~ "museum opens"
      assert document.attempts == [direct: :ok]
      assert document.cost == 0.0
    end

    test "converts a PDF with the configured converter" do
      plug = Fixtures.plug(200, "%PDF-1.7 bytes", [{"content-type", "application/pdf"}])

      assert {:ok, %Document{content_type: "application/pdf", markdown: markdown}} =
               Scrape.run("http://93.184.215.14/files/annual-report.pdf",
                 ladder: [:direct],
                 req_options: [plug: plug]
               )

      assert markdown =~ "# annual-report.pdf"
    end

    test "refuses a redirect to a private address" do
      restore = Fixtures.put_config(url_validator: nil)
      on_exit(restore)
      plug = Fixtures.plug(302, "", [{"location", "http://127.0.0.1/admin"}])

      assert Scrape.run(@url, ladder: [:direct], req_options: [plug: plug]) ==
               {:error, {:unreadable, %{attempts: [direct: :private_address], cost: 0.0}}}
    end
  end

  describe "run/2 text encoding" do
    test "decodes a declared Latin-1 body to UTF-8" do
      body =
        :unicode.characters_to_binary(
          "Café hours: " <> Fixtures.readable_text(),
          :unicode,
          :latin1
        )

      plug = Fixtures.plug(200, body, [{"content-type", "text/plain; charset=ISO-8859-1"}])

      assert {:ok, %Document{markdown: markdown}} =
               Scrape.run(@url, ladder: [:direct], req_options: [plug: plug])

      assert String.valid?(markdown)
      assert markdown =~ "Café hours"
    end

    test "replaces invalid bytes in an undeclared body instead of crashing later" do
      body = "Hours " <> <<0xFF, 0xFE>> <> " " <> Fixtures.readable_text()
      plug = Fixtures.plug(200, body, [{"content-type", "text/plain"}])

      assert {:ok, %Document{markdown: markdown}} =
               Scrape.run(@url, ladder: [:direct], req_options: [plug: plug])

      assert String.valid?(markdown)
    end
  end

  describe "run/2 converter failures" do
    test "a crashing PDF converter is an outcome, and the ladder moves on" do
      on_exit(Fixtures.put_config(pdf_converter: Fixtures.RaisingPdfConverter))
      plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

      assert {:ok, %Document{attempts: attempts}} =
               Scrape.run("http://93.184.215.14/files/report.pdf",
                 ladder: [:direct, {Scraper, reply: ok_reply()}],
                 req_options: [plug: plug]
               )

      assert attempts == [{:direct, :conversion_failed}, {Scraper, :ok}]
    end
  end

  describe "run/2 deadline" do
    test "skips the remaining rungs once the scrape's deadline has passed" do
      slow = fn _url ->
        Process.sleep(80)
        {:error, :blocked}
      end

      assert {:error, {:unreadable, %{attempts: attempts}}} =
               Scrape.run(@url,
                 ladder: [{Scraper, reply: slow}, {PaidScraper, reply: ok_reply()}],
                 timeout: 50
               )

      assert attempts == [{Scraper, :blocked}, {PaidScraper, :deadline}]
    end

    test "passes each rung the time left before the deadline" do
      test_pid = self()

      probe = fn _url, opts ->
        send(test_pid, {:time_left, Perplexed.Scraper.time_left(opts, 60_000)})
        {:ok, %Document{markdown: Fixtures.readable_text()}, nil}
      end

      assert {:ok, _document} =
               Scrape.run(@url, ladder: [{Fixtures.OptsScraper, reply: probe}], timeout: 5_000)

      assert_received {:time_left, left}
      assert left > 0 and left <= 5_000
    end
  end

  describe "run/2 URL guard" do
    test "a private URL is refused before any scraper, hosted ones included" do
      on_exit(Fixtures.put_config(url_validator: nil))

      assert Scrape.run("http://127.0.0.1/admin", ladder: [{PaidScraper, reply: ok_reply()}]) ==
               {:error,
                {:invalid_request, %{reason: :private_address, url: "http://127.0.0.1/admin"}}}
    end

    test "a redirect into a private network ends the ladder instead of reaching a hosted scraper" do
      on_exit(Fixtures.put_config(url_validator: nil))
      plug = Fixtures.plug(302, "", [{"location", "http://10.0.0.5/internal"}])

      assert {:error, {:unreadable, %{attempts: [direct: :private_address]}}} =
               Scrape.run("http://93.184.215.14/start",
                 ladder: [:direct, {PaidScraper, reply: ok_reply()}],
                 req_options: [plug: plug]
               )
    end

    test "an unknown ladder entry is an error naming it" do
      assert Scrape.run(@url, ladder: [:no_such_scraper]) ==
               {:error, {:invalid_request, %{reason: {:unknown_scraper, :no_such_scraper}}}}
    end
  end

  describe "run/2 ladder" do
    test "a Firecrawl site refusal preserves the outcome and tries the next scraper" do
      plug = Fixtures.json_plug(self(), 403, %{"error" => "We do not support this site"})

      assert {:ok, %Document{attempts: attempts}} =
               Scrape.run(@url,
                 ladder: [:firecrawl, {Scraper, reply: ok_reply()}],
                 credentials: [firecrawl_api_key: "test-key"],
                 req_options: [plug: plug]
               )

      assert attempts == [{:firecrawl, :blocked}, {Scraper, :ok}]
    end

    test "escalates past a refusal to the next scraper" do
      plug = Fixtures.plug(403, "Forbidden", [{"content-type", "text/html"}])

      assert {:ok, %Document{tier: Scraper, attempts: attempts}} =
               Scrape.run(@url,
                 ladder: [:direct, {Scraper, reply: ok_reply()}],
                 req_options: [plug: plug]
               )

      assert attempts == [{:direct, :blocked}, {Scraper, :ok}]
    end

    test "skips a scraper that cannot help with a JavaScript shell" do
      shell = fn _url ->
        {:ok, %Document{markdown: "Loading"}, ~s(<div id="root"></div>)}
      end

      assert {:ok, %Document{tier: Scraper, attempts: attempts}} =
               Scrape.run(@url,
                 ladder: [
                   {PaidScraper, reply: shell},
                   {BlockedOnlyScraper, reply: ok_reply()},
                   {Scraper, reply: ok_reply()}
                 ]
               )

      assert attempts == [{PaidScraper, :js_shell}, {Scraper, :ok}]
    end

    test "stops at a missing page" do
      plug = Fixtures.plug(404, "Not found", [{"content-type", "text/html"}])

      assert Scrape.run(@url,
               ladder: [:direct, {Scraper, reply: ok_reply()}],
               req_options: [plug: plug]
             ) == {:error, {:unreadable, %{attempts: [direct: :not_found], cost: 0.0}}}
    end

    test "a paid rung that answered but was unreadable still counts toward cost" do
      thin = fn _url -> {:ok, %Document{markdown: "Too short."}, nil} end

      assert {:ok, %Document{cost: cost, attempts: attempts}} =
               Scrape.run(@url,
                 ladder: [{PaidScraper, reply: thin}, {Scraper, reply: ok_reply()}]
               )

      assert attempts == [{PaidScraper, :thin}, {Scraper, :ok}]
      assert cost == 0.01
    end

    test "a failed scrape reports its attempts and what they cost" do
      thin = fn _url -> {:ok, %Document{markdown: "Too short."}, nil} end

      assert Scrape.run(@url, ladder: [{PaidScraper, reply: thin}]) ==
               {:error, {:unreadable, %{attempts: [{PaidScraper, :thin}], cost: 0.01}}}
    end

    test "an oversized page ends the ladder instead of paying a hosted scraper" do
      too_large = fn _url -> {:error, :too_large} end

      assert {:error, {:unreadable, %{attempts: [{Scraper, :too_large}]}}} =
               Scrape.run(@url,
                 ladder: [{Scraper, reply: too_large}, {PaidScraper, reply: ok_reply()}]
               )
    end

    test "records the cost of the scraper that produced the document" do
      assert {:ok, %Document{cost: 0.01}} =
               Scrape.run(@url, ladder: [{PaidScraper, reply: ok_reply()}])
    end

    test "defaults to the free tiers when no paid scraper has a key" do
      on_exit(Fixtures.put_config(deepseek_api_key: nil, firecrawl_api_key: nil))
      assert Scrape.default_ladder() == [:direct, :impersonated]
    end

    test "adds each configured paid scraper after the free tiers, cheapest first" do
      on_exit(Fixtures.put_config(firecrawl_api_key: "fc-key", deepseek_api_key: nil))
      assert Scrape.default_ladder() == [:direct, :impersonated, :firecrawl]

      on_exit(Fixtures.put_config(firecrawl_api_key: "fc-key", deepseek_api_key: "ds-key"))
      assert Scrape.default_ladder() == [:direct, :impersonated, :deepseek, :firecrawl]
    end

    test "per-call credentials add the paid scrapers too" do
      on_exit(Fixtures.put_config(deepseek_api_key: nil, firecrawl_api_key: nil))
      credentials = [deepseek_api_key: "ds-key", firecrawl_api_key: "fc-key"]

      assert Scrape.default_ladder(credentials: credentials) ==
               [:direct, :impersonated, :deepseek, :firecrawl]
    end

    test "a PDF no free tier converted ends the climb unless a later rung reads PDFs" do
      unsupported = fn _url -> {:error, :unsupported} end
      ladder = [{Scraper, reply: unsupported}, {PaidScraper, reply: ok_reply()}]

      assert {:error, {:unreadable, %{attempts: [{Scraper, :unsupported}]}}} =
               Scrape.run(@url, ladder: ladder)
    end

    test "firecrawl_pdf: true hands such a PDF to Firecrawl" do
      on_exit(Fixtures.put_config(firecrawl_api_key: "fc-key", firecrawl_pdf: true))
      unsupported = fn _url -> {:error, :unsupported} end

      plug =
        Fixtures.json_plug(self(), 200, %{
          "success" => true,
          "data" => %{"markdown" => Fixtures.readable_markdown()}
        })

      assert {:ok,
              %Document{tier: :firecrawl, attempts: [{Scraper, :unsupported}, firecrawl: :ok]}} =
               Scrape.run(@url,
                 ladder: [{Scraper, reply: unsupported}, :firecrawl],
                 req_options: [plug: plug]
               )

      Fixtures.put_config(firecrawl_pdf: false)

      assert {:error, {:unreadable, %{attempts: [{Scraper, :unsupported}]}}} =
               Scrape.run(@url,
                 ladder: [{Scraper, reply: unsupported}, :firecrawl],
                 req_options: [plug: plug]
               )
    end

    test "reports every rung it tries, with what it cost" do
      Fixtures.capture_telemetry([[:perplexed, :scrape, :attempt]])
      blocked = fn _url -> {:error, :blocked} end

      assert {:ok, _document} =
               Scrape.run(@url,
                 ladder: [{Scraper, reply: blocked}, {PaidScraper, reply: ok_reply()}]
               )

      assert_received {:telemetry, _, %{cost: +0.0},
                       %{tier: Scraper, outcome: :blocked, billable: false}}

      assert_received {:telemetry, _, %{cost: 0.01},
                       %{tier: PaidScraper, outcome: :ok, billable: true}}
    end

    test "a configured ladder replaces the default" do
      on_exit(Fixtures.put_config(ladder: [:direct, :browser_run]))
      assert Scrape.default_ladder() == [:direct, :browser_run]
    end

    test "rejects a blank URL" do
      assert Scrape.run("") == {:error, {:invalid_request, %{reason: :invalid_url, url: ""}}}
    end
  end

  describe "run/2 browser_run tier" do
    test "returns rendered Markdown with browser time and its cost" do
      plug =
        Fixtures.json_plug(
          self(),
          200,
          %{"success" => true, "result" => Fixtures.readable_text()},
          [
            {"x-browser-ms-used", "4000"}
          ]
        )

      assert {:ok, %Document{tier: :browser_run, browser_ms: 4000, cost: cost}} =
               Scrape.run(@url, ladder: [:browser_run], req_options: [plug: plug])

      assert_in_delta cost, 4000 * 0.09 / 3_600_000, 1.0e-12

      assert_received {:request, "/client/v4/accounts/acct/browser-run/markdown",
                       %{"url" => @url}}
    end

    test "is unreadable without Cloudflare credentials" do
      restore = Fixtures.put_config(cloudflare_api_token: nil)
      on_exit(restore)

      assert Scrape.run(@url, ladder: [:browser_run]) ==
               {:error, {:unreadable, %{attempts: [browser_run: :authentication], cost: 0.0}}}
    end
  end

  describe "batch/2" do
    @tag :capture_log
    test "returns results in input order and isolates a crashing scrape" do
      reply = fn
        "http://crash.test/" -> raise "boom"
        _url -> {:ok, %Document{markdown: Fixtures.readable_text()}, nil}
      end

      results =
        Scrape.batch(["http://a.test/", "http://crash.test/", "http://b.test/"],
          ladder: [{Scraper, reply: reply}]
        )

      assert [
               {"http://a.test/", {:ok, %Document{}}},
               {"http://crash.test/", {:error, {:exit, _reason}}},
               {"http://b.test/", {:ok, %Document{}}}
             ] = results
    end

    test "kills a scrape that runs past the timeout" do
      reply = fn _url ->
        Process.sleep(:infinity)
        {:ok, %Document{markdown: Fixtures.readable_text()}, nil}
      end

      assert [{"http://slow.test/", {:error, {:exit, %{reason: :timeout}}}}] =
               Scrape.batch(["http://slow.test/"], ladder: [{Scraper, reply: reply}], timeout: 50)
    end
  end
end
