defmodule Perplexed.Fixtures do
  @moduledoc """
  Test doubles and builders for Perplexed. Uses only Perplexed and ReqLLM so
  it moves with the library.
  """

  alias ReqLLM.{Context, Response}

  @readable String.duplicate("The museum opens at nine and closes at five on weekdays. ", 12)

  @doc "Page text long enough for `Perplexed.Verdict` to call readable."
  def readable_text, do: @readable

  @doc "An HTML page whose text is readable."
  def readable_html,
    do: "<html><body><main><h1>Visiting</h1><p>#{@readable}</p></main></body></html>"

  @doc "`url_validator` that allows every URL, so plug-backed tests need no DNS."
  def allow_url(url), do: {:ok, url}

  @doc "A Req plug answering every request with `status`, `body` and `headers`."
  def plug(status, body, headers \\ []) do
    fn conn ->
      conn =
        Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)

      Plug.Conn.send_resp(conn, status, body)
    end
  end

  @doc "A Req plug answering with JSON and capturing the request body to the test process."
  def json_plug(test_pid, status, payload, headers \\ []) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, Jason.decode!(body)})

      headers
      |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    end
  end

  @doc "Overrides Perplexed settings for one test; returns the function that restores them."
  def put_config(settings) do
    previous = Perplexed.Config.all()
    Perplexed.Config.put(Keyword.merge(previous, settings))
    fn -> Perplexed.Config.put(previous) end
  end

  @doc "A model response with plain text and no tool calls."
  def text_response(
        context,
        text,
        usage \\ %{input_tokens: 200, output_tokens: 20, total_cost: 0.002}
      ),
      do: respond(context, Context.assistant(text), usage)

  @doc "A structured-output response carrying `object`."
  def object_response(
        object,
        usage \\ %{input_tokens: 300, output_tokens: 30, total_cost: 0.003}
      ),
      do: %Response{
        id: "resp_object",
        model: "test:model",
        context: Context.new(),
        object: object,
        usage: usage
      }

  defp respond(context, message, usage) do
    %Response{
      id: "resp_#{System.unique_integer([:positive])}",
      model: "test:model",
      context: Context.append(context, message),
      message: message,
      usage: usage
    }
  end
end

defmodule Perplexed.Fixtures.Scraper do
  @moduledoc "Scraper stub: answers with `opts[:reply].(url)`."
  @behaviour Perplexed.Scraper

  @impl true
  def scrape(url, opts), do: Keyword.fetch!(opts, :reply).(url)
end

defmodule Perplexed.Fixtures.PaidScraper do
  @moduledoc "Scraper stub that bills $0.01 per document."
  @behaviour Perplexed.Scraper

  @impl true
  def scrape(url, opts), do: Keyword.fetch!(opts, :reply).(url)

  @impl true
  def cost(_document, _opts), do: 0.01
end

defmodule Perplexed.Fixtures.BlockedOnlyScraper do
  @moduledoc "Scraper stub that only retries after a `:blocked` outcome."
  @behaviour Perplexed.Scraper

  @impl true
  def scrape(url, opts), do: Keyword.fetch!(opts, :reply).(url)

  @impl true
  def retries?(outcome), do: outcome == :blocked
end

defmodule Perplexed.Fixtures.SearchProvider do
  @moduledoc "Search provider stub: answers with `opts[:reply].(query)`, priced $0.004."
  @behaviour Perplexed.Search

  @impl true
  def search(query, opts), do: Keyword.fetch!(opts, :reply).(query)

  @impl true
  def price(_opts), do: 0.004
end

defmodule Perplexed.Fixtures.PdfConverter do
  @moduledoc "PDF converter stub that returns readable text for any PDF."
  @behaviour Perplexed.PdfConverter

  @impl true
  def convert(_binary, filename),
    do: {:ok, "# #{filename}\n\n" <> Perplexed.Fixtures.readable_text()}
end

defmodule Perplexed.Fixtures.RaisingPdfConverter do
  @moduledoc "PDF converter stub that raises, like a crashing native converter."
  @behaviour Perplexed.PdfConverter

  @impl true
  def convert(_binary, _filename), do: raise("converter crashed")
end

defmodule Perplexed.Fixtures.NilPdfConverter do
  @moduledoc "PDF converter stub that breaks its contract with `{:ok, nil}`. Declares no behaviour, since it violates the callback's return type."

  def convert(_binary, _filename), do: {:ok, nil}
end

defmodule Perplexed.Fixtures.BareErrorPdfConverter do
  @moduledoc "PDF converter stub that breaks its contract with a bare `:error`. Declares no behaviour, since it violates the callback's return type."

  def convert(_binary, _filename), do: :error
end

defmodule Perplexed.Fixtures.OptsScraper do
  @moduledoc "Scraper stub: answers with `opts[:reply].(url, opts)`, so a test can see the options a rung gets."
  @behaviour Perplexed.Scraper

  @impl true
  def scrape(url, opts), do: Keyword.fetch!(opts, :reply).(url, opts)
end
