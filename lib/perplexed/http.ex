defmodule Perplexed.Http do
  @moduledoc false
  # JSON requests to provider APIs, with one error vocabulary for every
  # provider.
  #
  # Errors are `{:error, {reason, metadata}}` with `reason` one of
  # `:authentication`, `:quota_exhausted`, `:rate_limited`, `:not_found`,
  # `:blocked`, `:upstream`, `:invalid_response` or `:transport`. Credit, credential and
  # throttling failures also emit a `Perplexed.Telemetry` provider alert.

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.Telemetry

  @receive_timeout_ms 30_000
  @message_chars 300
  @billing_words ~r/credit|quota|balance|insufficient|payment/i

  @doc """
  POSTs `body` as JSON to `url` with a bearer `token` and classifies the reply.

  `opts[:receive_timeout]` defaults to #{@receive_timeout_ms} ms.
  `opts[:req_options]` is merged into the Req call last (tests pass `plug:`).
  """
  @spec post_json(atom(), String.t(), map(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, {atom(), map()}}
  def post_json(provider, url, body, token, opts \\ []) do
    [
      url: url,
      json: body,
      auth: {:bearer, token},
      retry: &retry?/2,
      max_retries: 1,
      receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout_ms)
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.post()
    |> classify(provider, url)
  end

  @doc "Classifies a Req result into `{:ok, response}` or a provider error."
  @spec classify({:ok, Req.Response.t()} | {:error, term()}, atom(), String.t()) ::
          {:ok, Req.Response.t()} | {:error, {atom(), map()}}
  def classify({:ok, %Req.Response{status: status} = response}, _provider, _url)
      when status in 200..299,
      do: {:ok, response}

  def classify({:ok, %Req.Response{status: status, body: body} = response}, provider, url) do
    message = message(body)
    reason = response_reason(provider, status, body, message)

    metadata =
      put_wait(
        %{provider: provider, url: url, status: status, message: message},
        retry_after_ms(response)
      )

    Telemetry.maybe_alert(provider, reason, metadata)
    {:error, {reason, metadata}}
  end

  def classify({:error, exception}, provider, url),
    do:
      {:error, {:transport, %{provider: provider, url: url, reason: transport_reason(exception)}}}

  @doc """
  How long the server asked us to wait, in ms: `Retry-After` (seconds or an
  HTTP date), else the IETF `RateLimit-Reset` (seconds), else
  `X-RateLimit-Reset` (seconds, or a Unix time when that large). `nil` for a
  2xx reply or when it sent none.
  """
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{status: status}) when status in 200..299, do: nil

  def retry_after_ms(response) do
    [
      {"retry-after", &retry_after/1},
      {"ratelimit-reset", &seconds/1},
      {"x-ratelimit-reset", &reset_time/1}
    ]
    |> Enum.find_value(fn {header, parse} ->
      response |> Req.Response.get_header(header) |> List.first() |> parse_header(parse)
    end)
  end

  defp parse_header(nil, _parse), do: nil
  defp parse_header(value, parse), do: value |> String.trim() |> parse.()

  defp retry_after(value), do: seconds(value) || http_date(value)

  defp seconds(value), do: value |> Integer.parse() |> seconds_ms()

  defp seconds_ms({seconds, ""}) when seconds >= 0, do: seconds * 1000
  defp seconds_ms(_invalid), do: nil

  defp reset_time(value), do: value |> Integer.parse() |> reset_ms()

  @unix_time_floor 1_000_000_000
  defp reset_ms({at, ""}) when at >= @unix_time_floor,
    do: max(at - System.os_time(:second), 0) * 1000

  defp reset_ms(parsed), do: seconds_ms(parsed)

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  # RFC 9110 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT".
  defp http_date(value) do
    with [_, day, month, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time) do
      max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
    else
      _invalid -> nil
    end
  end

  @doc "An `:invalid_response` error for a body that is not the documented shape."
  @spec invalid_response(atom(), String.t(), term()) :: {:error, {:invalid_response, map()}}
  def invalid_response(provider, url, body),
    do: {:error, {:invalid_response, %{provider: provider, url: url, message: message(body)}}}

  # How long the provider asked us to wait, when it said.
  defp put_wait(metadata, nil), do: metadata
  defp put_wait(metadata, ms), do: Map.put(metadata, :retry_after_ms, ms)

  # A Firecrawl site-policy refusal is a per-URL outcome, not a credential failure.
  defp response_reason(:firecrawl, 403, body, message) do
    if unsupported_site?(body, message), do: :blocked, else: :authentication
  end

  defp response_reason(_provider, status, _body, message), do: status_reason(status, message)

  defp unsupported_site?(%{"code" => "UNSUPPORTED_SITE"}, _message), do: true

  defp unsupported_site?(_body, message) when is_present(message) do
    normalized = String.downcase(message)
    normalized == "unsupported_site" or String.contains?(normalized, "do not support this site")
  end

  defp unsupported_site?(_body, _message), do: false

  defp status_reason(status, _message) when status in [401, 403], do: :authentication
  defp status_reason(402, _message), do: :quota_exhausted
  defp status_reason(404, _message), do: :not_found

  # "Rate limit exceeded" is throttling; only billing words mean credits ran out.
  defp status_reason(429, message) when is_present(message),
    do: message |> String.match?(@billing_words) |> throttle_reason()

  defp status_reason(429, _message), do: :rate_limited
  defp status_reason(status, _message) when status >= 500, do: :upstream
  defp status_reason(_status, _message), do: :invalid_response

  defp throttle_reason(true), do: :quota_exhausted
  defp throttle_reason(false), do: :rate_limited

  # The provider's error text, bounded to @message_chars characters.
  defp message(body), do: body |> message_text() |> bounded()

  defp message_text(%{"error" => %{"message" => message}}) when is_present(message), do: message
  defp message_text(%{"error" => message}) when is_present(message), do: message
  defp message_text(%{"message" => message}) when is_present(message), do: message

  defp message_text(%{"errors" => [%{"message" => message} | _rest]}) when is_present(message),
    do: message

  defp message_text(body) when is_present(body), do: body
  defp message_text(_body), do: nil

  defp bounded(nil), do: nil
  defp bounded(text), do: String.slice(text, 0, @message_chars)

  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(exception), do: exception

  defp retry?(_request, %Req.Response{status: status}), do: status in [408, 500, 502, 503, 504]
  # A timed-out request may have been processed and billed, so it is not sent again.
  defp retry?(_request, %Req.TransportError{reason: reason}) when reason in [:nxdomain, :timeout],
    do: false

  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, _other), do: false
end
