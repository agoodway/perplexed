defmodule Perplexed.Http do
  @moduledoc false
  # JSON requests to provider APIs, with one error vocabulary for every
  # provider.
  #
  # Errors are `{:error, {reason, metadata}}` with `reason` one of
  # `:authentication`, `:quota_exhausted`, `:rate_limited`, `:not_found`,
  # `:upstream`, `:invalid_response` or `:transport`. Credit, credential and
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

  def classify({:ok, %Req.Response{status: status, body: body}}, provider, url) do
    message = message(body)
    reason = status_reason(status, message)
    metadata = %{provider: provider, url: url, status: status, message: message}
    Telemetry.maybe_alert(provider, reason, metadata)
    {:error, {reason, metadata}}
  end

  def classify({:error, exception}, provider, url),
    do:
      {:error, {:transport, %{provider: provider, url: url, reason: transport_reason(exception)}}}

  @doc "An `:invalid_response` error for a body that is not the documented shape."
  @spec invalid_response(atom(), String.t(), term()) :: {:error, {:invalid_response, map()}}
  def invalid_response(provider, url, body),
    do: {:error, {:invalid_response, %{provider: provider, url: url, message: message(body)}}}

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
