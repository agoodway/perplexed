defmodule Perplexed.Scraper.Http do
  @moduledoc false
  # Shared download-and-convert step for the scrapers that fetch pages
  # themselves (`Perplexed.Scraper.Direct`, `Perplexed.Scraper.Impersonated`).
  #
  # Redirects are followed one hop at a time so `Perplexed.UrlGuard` checks
  # every target before it is requested. Bodies are capped at 25 MB, and a
  # body still arriving when the scrape's deadline passes is abandoned. Text is
  # decoded to UTF-8 (a declared Latin-1, ASCII or Windows-1252 charset is decoded as
  # Windows-1252;
  # other invalid bytes are replaced). HTML becomes Markdown with
  # Html2Markdown; PDFs go to the configured `Perplexed.PdfConverter`. A
  # converter that raises or exits is the `:conversion_failed` outcome, so the
  # ladder can try the next scraper.

  alias Perplexed.{Clock, Document, PdfConverter, Scraper, UrlGuard}

  @timeout_ms 15_000
  @max_size_bytes 25 * 1024 * 1024
  @max_redirects 5
  @html_types ~w(text/html application/xhtml+xml)
  @text_types ~w(text/plain text/markdown application/json)
  @blocked_statuses [401, 403, 429, 503]
  @gone_statuses [404, 410]
  # Labels the WHATWG Encoding standard (what browsers implement) decodes as
  # windows-1252, since servers routinely mislabel it as Latin-1 or ASCII.
  @windows_1252_charsets ~w(windows-1252 cp1252 iso-8859-1 latin1 latin-1 us-ascii ascii)
  # The printable characters windows-1252 puts in 0x80-0x9F; every other
  # byte is the Latin-1 code point of the same value.
  @windows_1252 %{
    0x80 => "€",
    0x82 => "‚",
    0x83 => "ƒ",
    0x84 => "„",
    0x85 => "…",
    0x86 => "†",
    0x87 => "‡",
    0x88 => "ˆ",
    0x89 => "‰",
    0x8A => "Š",
    0x8B => "‹",
    0x8C => "Œ",
    0x8E => "Ž",
    0x91 => "‘",
    0x92 => "’",
    0x93 => "“",
    0x94 => "”",
    0x95 => "•",
    0x96 => "–",
    0x97 => "—",
    0x98 => "˜",
    0x99 => "™",
    0x9A => "š",
    0x9B => "›",
    0x9C => "œ",
    0x9E => "ž",
    0x9F => "Ÿ"
  }

  @doc """
  Fetches `url` and converts the body to a document.

  `transport` adds `:headers` to the request, or names a `CloakedReq`
  `:impersonate` profile. `opts[:req_options]` is merged into each Req call
  (tests pass `plug:`). Each wait is `opts[:timeout_ms]` (default
  #{@timeout_ms}), capped by the time left before `opts[:deadline]`.
  """
  @spec scrape(String.t(), keyword(), keyword()) ::
          {:ok, Document.t(), String.t() | nil} | {:error, atom()}
  def scrape(url, opts, transport) do
    with {:ok, response, final_url} <- get(url, opts, transport, @max_redirects) do
      convert(response, final_url, opts)
    end
  end

  defp get(url, opts, transport, hops) do
    with {:ok, url} <- UrlGuard.check(url, opts) do
      url |> request(opts, transport) |> fetched(url) |> follow(url, opts, transport, hops)
    end
  end

  defp follow({:redirect, location}, url, opts, transport, hops) when hops > 0,
    do: get(url |> URI.merge(location) |> URI.to_string(), opts, transport, hops - 1)

  defp follow({:redirect, _location}, _url, _opts, _transport, _hops),
    do: {:error, :too_many_redirects}

  defp follow(result, _url, _opts, _transport, _hops), do: result

  defp request(url, opts, transport) do
    [
      url: url,
      headers: Keyword.get(transport, :headers, []),
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: Scraper.time_left(opts, Keyword.get(opts, :timeout_ms, @timeout_ms))
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
    |> put_transport(Keyword.get(transport, :impersonate), Keyword.get(opts, :deadline))
    |> Req.request()
  end

  # CloakedReq rejects `into:`, so an impersonated request caps the body with
  # the adapter's `max_body_size` instead of the streaming collector.
  defp put_transport(request, nil, deadline),
    do: Req.merge(request, into: capped_collector(deadline))

  defp put_transport(request, profile, _deadline) when is_atom(profile),
    do: CloakedReq.attach(request, impersonate: profile, max_body_size: @max_size_bytes)

  # Appends each chunk in place (`<<body::binary, data::binary>>` reuses the
  # binary's spare capacity), stopping at the size cap or the deadline.
  defp capped_collector(deadline) do
    fn {:data, data}, {request, response} ->
      body = <<binary_body(response)::binary, data::binary>>

      cond do
        byte_size(body) > @max_size_bytes -> halt(request, response, :too_large)
        Clock.past?(deadline) -> halt(request, response, :deadline)
        true -> {:cont, {request, %{response | body: body}}}
      end
    end
  end

  defp binary_body(%Req.Response{body: body}) when is_binary(body), do: body
  defp binary_body(%Req.Response{}), do: ""

  defp halt(request, response, reason),
    do: {:halt, {request, Req.Response.put_private(%{response | body: ""}, :stopped, reason)}}

  defp fetched({:ok, %Req.Response{status: status} = response}, _url) when status in 300..399,
    do: response |> Req.Response.get_header("location") |> redirect()

  defp fetched({:ok, %Req.Response{status: status} = response}, url) when status in 200..299,
    do: response |> Req.Response.get_private(:stopped) |> completed(response, url)

  defp fetched({:ok, %Req.Response{status: status}}, _url) when status in @gone_statuses,
    do: {:error, :not_found}

  defp fetched({:ok, %Req.Response{status: status}}, _url) when status in @blocked_statuses,
    do: {:error, :blocked}

  defp fetched({:ok, %Req.Response{}}, _url), do: {:error, :http_error}
  defp fetched({:error, %Req.TransportError{reason: :timeout}}, _url), do: {:error, :timeout}

  # CloakedReq reports a response over `max_body_size` as an adapter error
  # whose details carry the limit.
  defp fetched({:error, %CloakedReq.AdapterError{error: %{details: %{"limit" => _limit}}}}, _url),
    do: {:error, :too_large}

  defp fetched({:error, _exception}, _url), do: {:error, :download_failed}

  defp redirect([location | _rest]), do: {:redirect, location}
  defp redirect([]), do: {:error, :download_failed}

  # The body collector records why it stopped early (`:too_large`, `:deadline`).
  defp completed(nil, response, url), do: {:ok, response, url}
  defp completed(stopped, _response, _url), do: {:error, stopped}

  defp convert(%Req.Response{body: body} = response, final_url, opts) do
    {type, charset} = content_type(response, final_url)
    converted(type, body, charset, final_url, opts)
  end

  defp converted("application/pdf", body, _charset, final_url, opts),
    do:
      fn -> PdfConverter.convert(body, filename(final_url), opts) end
      |> guarded()
      |> pdf_document(final_url)

  defp converted(type, body, charset, final_url, _opts) when type in @html_types do
    html = utf8(body, charset)

    fn -> Html2Markdown.convert(html) end
    |> guarded()
    |> html_document(type, final_url, html)
  end

  defp converted(type, body, charset, final_url, _opts) when type in @text_types,
    do:
      {:ok, %Document{markdown: utf8(body, charset), content_type: type, final_url: final_url},
       nil}

  defp converted(_type, _body, _charset, _final_url, _opts), do: {:error, :unsupported}

  # A converter that breaks its contract is a conversion failure too.
  defp pdf_document({:ok, markdown}, final_url) when is_binary(markdown),
    do:
      {:ok,
       %Document{
         markdown: String.replace_invalid(markdown),
         content_type: "application/pdf",
         final_url: final_url
       }, nil}

  defp pdf_document({:error, reason}, _final_url) when is_atom(reason), do: {:error, reason}
  defp pdf_document(_other, _final_url), do: {:error, :conversion_failed}

  defp html_document(markdown, type, final_url, html) when is_binary(markdown),
    do: {:ok, %Document{markdown: markdown, content_type: type, final_url: final_url}, html}

  defp html_document(_other, _type, _final_url, _html), do: {:error, :conversion_failed}

  # Html2Markdown and the configured PDF converter are third-party code; a
  # raise or exit inside them becomes an outcome the ladder can move past
  # rather than discarding the whole scrape.
  defp guarded(fun) do
    fun.()
  rescue
    _exception -> {:error, :conversion_failed}
  catch
    kind, _reason when kind in [:exit, :throw] -> {:error, :conversion_failed}
  end

  defp utf8(body, charset), do: decode(String.valid?(body), body, charset)

  defp decode(true, body, _charset), do: body

  defp decode(false, body, charset) when charset in @windows_1252_charsets,
    do:
      for(<<byte <- body>>,
        into: "",
        do: Map.get_lazy(@windows_1252, byte, fn -> <<byte::utf8>> end)
      )

  defp decode(false, body, _charset), do: String.replace_invalid(body)

  # `{media_type, charset}`, both lowercase; the type falls back to the URL's
  # extension and the charset to nil.
  defp content_type(response, url),
    do: response |> Req.Response.get_header("content-type") |> media_type(url)

  defp media_type([value | _rest], _url) do
    [type | params] = value |> String.downcase() |> String.split(";")
    {String.trim(type), charset(params)}
  end

  defp media_type([], url), do: {MIME.from_path(URI.parse(url).path || ""), nil}

  defp charset(params), do: Enum.find_value(params, &charset_param/1)

  defp charset_param(param),
    do: param |> String.split("=", parts: 2) |> Enum.map(&String.trim/1) |> charset_value()

  defp charset_value(["charset", value]), do: String.trim(value, "\"")
  defp charset_value(_other), do: nil

  defp filename(url), do: (URI.parse(url).path || "") |> Path.basename() |> pdf_name()

  defp pdf_name(""), do: "document.pdf"
  defp pdf_name(name), do: name
end
