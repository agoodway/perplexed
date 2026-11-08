defmodule Perplexed.Search.DeepSeek do
  @moduledoc """
  DeepSeek Search API (`POST /v1/tools/search`) as a `Perplexed.Search` provider.

  Each result carries a 600 to 800 character `summary` written for a model to
  read, which becomes the hit's `description`. `need_content: true` (the
  default here) also returns available page text at no extra cost. Queries
  are capped at 128 characters. Billed $0.75 per 1,000 successful requests;
  empty results are not billed. Searches are processed by DeepSeek.

  Needs `config :perplexed, deepseek_api_key:`.
  """

  @behaviour Perplexed.Search

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Http}
  alias Perplexed.Search.Hit

  @url "https://api.deepseek.com/v1/tools/search"
  @default_limit 8
  @max_query_length 128
  @timeout_ms 20_000

  @impl true
  def price(_opts), do: 0.00075

  @impl true
  def free_when_empty?, do: true

  @impl true
  def search(query, opts) when is_present(query) do
    body = %{
      "query" => query |> String.trim() |> String.slice(0, @max_query_length),
      "count" => Keyword.get(opts, :limit, @default_limit),
      "need_content" => Keyword.get(opts, :need_content, true)
    }

    with {:ok, key} <- Config.credential(:deepseek_api_key, :deepseek, opts) do
      :deepseek
      |> Http.post_json(@url, body, key,
        receive_timeout: @timeout_ms,
        req_options: Keyword.get(opts, :req_options, [])
      )
      |> hits()
    end
  end

  def search(_query, _opts), do: {:error, {:invalid_request, %{reason: :empty_query}}}

  defp hits({:ok, %Req.Response{body: %{"results" => results}}}) when is_list(results),
    do: {:ok, results |> Enum.filter(&is_present(&1["url"])) |> Enum.map(&hit/1)}

  defp hits({:ok, %Req.Response{body: body}}), do: Http.invalid_response(:deepseek, @url, body)
  defp hits({:error, _reason} = error), do: error

  defp present(value) when is_present(value), do: value
  defp present(_blank), do: nil

  defp hit(%{"url" => url} = result) do
    %Hit{
      url: url,
      title: result["title"],
      description: result["summary"] || result["snippet"],
      content: present(result["content"]),
      published_at: result["date"],
      provider: :deepseek
    }
  end
end
