defmodule Perplexed.Search.SearXNG.Parser do
  @moduledoc false
  # Turns one SearXNG response into hits, or says why it has none.
  #
  # A real results page carries `<div id="urls">`; any other 200 from a
  # public instance is a bot check in front of it (Anubis, a "checking your
  # browser" page, the Portico proof of work), reported as `:challenge` so
  # the waterfall moves on. Challenges and redirects are detected, never
  # worked around.
  #
  # An instance is a third party, so nothing in its answer is trusted to
  # have the documented shape: fields of the wrong type become nil, entries
  # that are not objects are skipped, and engine names are kept only when
  # they look like engine names.

  import Perplexed.Guards, only: [presence: 1]

  alias Perplexed.Search.Hit

  @max_engines 8
  @engine_name ~r/\A[\w .-]{1,32}\z/u

  @type reason :: :rate_limited | :blocked | :unavailable | :http_error

  @doc "Hits from one response with `status` and `body`, or the reason there are none."
  @spec parse(pos_integer(), binary(), :html | :json) :: {:ok, [Hit.t()]} | {:error, atom()}
  def parse(200, body, :json), do: body |> Jason.decode() |> json_hits()
  def parse(200, body, :html), do: body |> Floki.parse_document() |> html_hits()
  def parse(status, _body, _format), do: {:error, status_reason(status)}

  @doc """
  Why a non-200 reply refused us. SearXNG's bot detection answers a repeat
  client with a redirect to the start page, so a 3xx is a refusal too.
  """
  @spec status_reason(pos_integer()) :: reason()
  def status_reason(429), do: :rate_limited
  def status_reason(503), do: :unavailable
  def status_reason(status) when status in 300..399, do: :blocked
  def status_reason(status) when status in [202, 401, 403, 418], do: :blocked
  def status_reason(_status), do: :http_error

  defp json_hits({:ok, %{"results" => results}}) when is_list(results),
    do: results |> Enum.flat_map(&json_hit/1) |> nonempty()

  defp json_hits(_other), do: {:error, :challenge}

  defp json_hit(%{} = result),
    do: [
      %Hit{
        url: presence(result["url"]),
        title: presence(result["title"]),
        description: presence(result["content"]),
        published_at: presence(result["publishedDate"]),
        engines: engines(result["engines"] || List.wrap(result["engine"])),
        provider: :searxng
      }
    ]

  defp json_hit(_not_an_object), do: []

  defp html_hits({:ok, document}), do: document |> Floki.find("#urls") |> results()
  defp html_hits({:error, _reason}), do: {:error, :challenge}

  defp results([]), do: {:error, :challenge}

  defp results(urls),
    do: urls |> Floki.find("article.result") |> Enum.map(&html_hit/1) |> nonempty()

  defp html_hit(article) do
    link = Floki.find(article, "h3 a")

    %Hit{
      url: link |> Floki.attribute("href") |> List.first(),
      title: link |> Floki.text() |> squish(),
      description: article |> Floki.find("p.content") |> Floki.text() |> squish() |> presence(),
      engines: article |> Floki.find(".engines span") |> Enum.map(&text/1) |> engines(),
      provider: :searxng
    }
  end

  defp text(node), do: node |> Floki.text() |> squish()

  # Engine names reach the ranking prompt, so only short plain names pass.
  defp engines(names) when is_list(names),
    do: names |> Enum.filter(&engine_name?/1) |> Enum.uniq() |> Enum.take(@max_engines)

  defp engines(_not_a_list), do: []

  defp engine_name?(name) when is_binary(name), do: Regex.match?(@engine_name, name)
  defp engine_name?(_other), do: false

  defp nonempty(hits), do: hits |> Enum.filter(&http_url?(&1.url)) |> found()

  defp found([]), do: {:error, :no_results}
  defp found(hits), do: {:ok, hits}

  defp http_url?("http://" <> _rest), do: true
  defp http_url?("https://" <> _rest), do: true
  defp http_url?(_other), do: false

  defp squish(text), do: text |> String.split() |> Enum.join(" ")
end
