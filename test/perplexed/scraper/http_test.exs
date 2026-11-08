defmodule Perplexed.Scraper.HttpTest do
  # Sets the configured PDF converter.
  use ExUnit.Case, async: false

  alias Perplexed.{Document, Fixtures}
  alias Perplexed.Scraper.Direct

  @base "https://example.org"

  setup do
    restore = Fixtures.put_config(pdf_converter: Fixtures.PdfConverter)
    on_exit(restore)
  end

  defp scrape(url, plug, extra \\ []) do
    Direct.scrape(
      url,
      [url_validator: {Fixtures, :allow_url, []}, req_options: [plug: plug]] ++ extra
    )
  end

  defp redirecting(location, status \\ 302) do
    Fixtures.plug(status, "", [{"location", location}])
  end

  describe "redirects" do
    test "follows a relative Location against the current URL" do
      plug = fn
        %{request_path: "/docs/start"} = conn ->
          redirecting("../final", 301).(conn)

        conn ->
          Fixtures.plug(200, "plain page", [{"content-type", "text/plain"}]).(conn)
      end

      assert {:ok, %Document{markdown: "plain page", final_url: final}, nil} =
               scrape("#{@base}/docs/start", plug)

      assert final == "#{@base}/final"
    end

    test "a 3xx without Location is a failed download" do
      assert scrape("#{@base}/a", Fixtures.plug(302, "")) == {:error, :download_failed}
    end

    test "gives up after more than five redirects" do
      {:ok, hops} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        n = Agent.get_and_update(hops, &{&1, &1 + 1})
        redirecting("/hop/#{n}").(conn)
      end

      assert scrape("#{@base}/start", plug) == {:error, :too_many_redirects}
      assert Agent.get(hops, & &1) == 6
    end

    test "follows exactly five redirects" do
      plug = fn conn ->
        case conn.request_path do
          "/hop/5" -> Fixtures.plug(200, "arrived", [{"content-type", "text/plain"}]).(conn)
          "/start" -> redirecting("/hop/1").(conn)
          "/hop/" <> n -> redirecting("/hop/#{String.to_integer(n) + 1}").(conn)
        end
      end

      assert {:ok, %Document{markdown: "arrived"}, nil} = scrape("#{@base}/start", plug)
    end

    test "checks each redirect target with the URL validator" do
      validator = {__MODULE__, :refuse_admin, []}
      plug = redirecting("https://example.org/admin")

      assert Direct.scrape("#{@base}/start",
               url_validator: validator,
               req_options: [plug: plug]
             ) == {:error, :forbidden}
    end
  end

  def refuse_admin("https://example.org/admin" <> _rest), do: {:error, :forbidden}
  def refuse_admin(url), do: {:ok, url}

  describe "status mapping" do
    for {status, outcome} <- [
          {404, :not_found},
          {410, :not_found},
          {401, :blocked},
          {403, :blocked},
          {429, :blocked},
          {503, :blocked},
          {500, :http_error},
          {418, :http_error}
        ] do
      test "#{status} is #{outcome}" do
        assert scrape("#{@base}/a", Fixtures.plug(unquote(status), "")) ==
                 {:error, unquote(outcome)}
      end
    end

    test "a transport timeout is :timeout" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end
      assert scrape("#{@base}/a", plug) == {:error, :timeout}
    end

    test "another transport error is a failed download" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end
      assert scrape("#{@base}/a", plug) == {:error, :download_failed}
    end
  end

  describe "content types" do
    test "falls back to the URL extension when the header is missing" do
      for {path, type, body, expected} <- [
            {"page.html", "text/html", "<html><body><p>Hello there</p></body></html>",
             "Hello there"},
            {"notes.md", "text/markdown", "# Notes", "# Notes"},
            {"data.json", "application/json", ~s({"a": 1}), ~s({"a": 1})}
          ] do
        assert {:ok, %Document{content_type: ^type, markdown: markdown}, _raw} =
                 scrape("#{@base}/#{path}", Fixtures.plug(200, body)),
               path

        assert markdown =~ expected, path
      end
    end

    test "treats a headerless .pdf URL as a PDF" do
      assert {:ok, %Document{content_type: "application/pdf", markdown: markdown}, nil} =
               scrape("#{@base}/files/report.pdf", Fixtures.plug(200, "%PDF-1.7"))

      assert markdown =~ "# report.pdf"
    end

    test "a PDF at a URL with no file name is named document.pdf" do
      plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

      assert {:ok, %Document{markdown: markdown}, nil} = scrape("#{@base}/", plug)
      assert markdown =~ "# document.pdf"
    end

    test "an unknown type is unsupported" do
      plug = Fixtures.plug(200, "bytes", [{"content-type", "image/png"}])
      assert scrape("#{@base}/logo", plug) == {:error, :unsupported}
    end

    test "an unknown extension without a header is unsupported" do
      assert scrape("#{@base}/archive.bin", Fixtures.plug(200, "bytes")) == {:error, :unsupported}
      assert scrape("#{@base}/noextension", Fixtures.plug(200, "bytes")) == {:error, :unsupported}
    end

    test "a PDF without a configured converter is unsupported" do
      restore = Fixtures.put_config(pdf_converter: nil)
      on_exit(restore)
      plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

      assert scrape("#{@base}/report.pdf", plug) == {:error, :unsupported}
    end

    test "a raising PDF converter is a conversion failure" do
      restore = Fixtures.put_config(pdf_converter: Fixtures.RaisingPdfConverter)
      on_exit(restore)
      plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

      assert scrape("#{@base}/report.pdf", plug) == {:error, :conversion_failed}
    end
  end

  describe "converter contract violations" do
    for converter <- [Fixtures.NilPdfConverter, Fixtures.BareErrorPdfConverter] do
      test "#{inspect(converter)} is a conversion failure" do
        restore = Fixtures.put_config(pdf_converter: unquote(converter))
        on_exit(restore)
        plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

        assert scrape("#{@base}/report.pdf", plug) == {:error, :conversion_failed}
      end
    end

    test "a per-call pdf_converter wins over the configured one" do
      plug = Fixtures.plug(200, "%PDF-1.7", [{"content-type", "application/pdf"}])

      assert scrape("#{@base}/report.pdf", plug, pdf_converter: Fixtures.NilPdfConverter) ==
               {:error, :conversion_failed}
    end
  end

  describe "text decoding" do
    test "reads a charset parameter with spaces around the equals sign" do
      plug =
        Fixtures.plug(200, <<0x93, "Quoted", 0x94>>, [
          {"content-type", "text/plain; charset = windows-1252"}
        ])

      assert {:ok, %Document{markdown: "“Quoted”"}, nil} = scrape("#{@base}/a", plug)
    end

    test "reads a quoted charset parameter and decodes Latin-1 bytes" do
      plug =
        Fixtures.plug(200, <<"caf", 0xE9>>, [
          {"content-type", ~s(text/plain; charset="ISO-8859-1")}
        ])

      assert {:ok, %Document{markdown: "café"}, nil} = scrape("#{@base}/a", plug)
    end

    test "decodes windows-1252 punctuation in the 0x80-0x9F range" do
      body =
        <<0x93>> <> "Quoted" <> <<0x94>> <> " " <> <<0x96>> <> " " <> Fixtures.readable_text()

      plug = Fixtures.plug(200, body, [{"content-type", "text/plain; charset=windows-1252"}])

      assert {:ok, %Document{markdown: markdown}, nil} = scrape("#{@base}/quotes", plug)

      assert markdown =~ "“Quoted” –"
    end

    test "decodes windows-1252 declared text" do
      plug =
        Fixtures.plug(200, <<"na", 0xEF, "ve">>, [
          {"content-type", "text/plain; charset=windows-1252"}
        ])

      assert {:ok, %Document{markdown: "naïve"}, nil} = scrape("#{@base}/a", plug)
    end

    test "replaces invalid bytes when no Latin-1 charset is declared" do
      plug =
        Fixtures.plug(200, <<"ab", 0xFF, "cd">>, [{"content-type", "text/plain; charset=utf-8"}])

      assert {:ok, %Document{markdown: markdown}, nil} = scrape("#{@base}/a", plug)
      assert String.valid?(markdown)
      assert markdown =~ "ab" and markdown =~ "cd"
    end

    test "keeps valid UTF-8 as it is whatever the declared charset" do
      plug = Fixtures.plug(200, "café", [{"content-type", "text/plain; charset=iso-8859-1"}])
      assert {:ok, %Document{markdown: "café"}, nil} = scrape("#{@base}/a", plug)
    end

    test "HTML keeps its raw markup for the verdict" do
      plug = Fixtures.plug(200, Fixtures.readable_html(), [{"content-type", "text/html"}])

      assert {:ok, %Document{content_type: "text/html"}, raw} = scrape("#{@base}/a", plug)
      assert raw == Fixtures.readable_html()
    end
  end
end
