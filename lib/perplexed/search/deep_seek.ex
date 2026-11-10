defmodule Perplexed.Search.DeepSeek do
  @moduledoc """
  DeepSeek Search API (`POST /v1/tools/search`) as a `Perplexed.Search` provider.

  Each result carries two query-dependent summaries: a 100 to 200
  character `snippet` for display and a 600 to 800 character `summary`
  written for a model to read, which becomes the hit's `description`. They
  are summaries, not the page: with `need_content: true` (the default here)
  DeepSeek also returns the page text, at no extra cost, as the hit's
  `content`, and `Perplexed.answer/2` reads that instead of scraping the
  page again. Everything else DeepSeek returns is kept in the hit's
  `metadata`: `snippet`, `rerank_score` (0 to 3, combining relevance,
  authority and freshness; 1.5 or above is high quality), `authority` (0 to
  4, 3 or above highly authoritative, -1 unknown), `site_name` and
  `site_icon`.

  ## Options

    * `:limit` - results, 1 to 50, default 8. The price is per request
      whatever the count.
    * `:question` - the user's original question, sent as `ori_question`
      (DeepSeek uses it to understand the query); `Perplexed.answer/2` sets
      it. Capped at 128 characters, like the query.
    * `:need_content` - return page text, default `true`.
    * `:localization` - an IP address to localize results for.
    * `:min_rerank_score`, `:min_authority` - drop results below these.

  Queries accept `site:`, `-site:`, `"exact"`, `-term`, `lang:`, `after:`
  and `before:`. Billed $0.75 per 1,000 successful requests; empty results,
  failures and timeouts are not billed. Searches are processed by DeepSeek.

  Needs `config :perplexed, deepseek_api_key:`.
  """

  @behaviour Perplexed.Search

  import Perplexed.Guards, only: [is_present: 1, presence: 1]

  alias Perplexed.{Config, Http}
  alias Perplexed.Search.Hit

  @url "https://api.deepseek.com/v1/tools/search"
  # $0.75 per 1,000 successful requests, as of 2026-11-10 (api-docs.deepseek.com).
  @usd_per_request 0.00075
  @default_limit 8
  @max_limit 50
  @max_text_length 128
  @timeout_ms 20_000

  @impl true
  def price(_opts), do: @usd_per_request

  @impl true
  def free_when_empty?, do: true

  @impl true
  def search(query, opts) when is_present(query) do
    with {:ok, key} <- Config.credential(:deepseek_api_key, :deepseek, opts) do
      :deepseek
      |> Http.post_json(@url, body(query, opts), key,
        receive_timeout: @timeout_ms,
        req_options: Keyword.get(opts, :req_options, [])
      )
      |> hits(opts)
    end
  end

  def search(_query, _opts), do: {:error, {:invalid_request, %{reason: :empty_query}}}

  @doc false
  # The request body for `query` and `opts`.
  @spec body(String.t(), keyword()) :: map()
  def body(query, opts) do
    %{
      "query" => capped(query),
      "count" => opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit),
      "need_content" => Keyword.get(opts, :need_content, true)
    }
    |> put_present("ori_question", opts |> Keyword.get(:question) |> capped())
    |> put_present("localization", Keyword.get(opts, :localization))
  end

  defp capped(text) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, @max_text_length)

  defp capped(_absent), do: nil

  defp put_present(body, key, value) when is_present(value), do: Map.put(body, key, value)
  defp put_present(body, _key, _blank), do: body

  defp hits({:ok, %Req.Response{body: %{"results" => results}}}, opts) when is_list(results),
    do:
      {:ok,
       for(
         result <- results,
         is_present(result["url"]),
         wanted?(result, opts),
         do: hit(result)
       )}

  defp hits({:ok, %Req.Response{body: body}}, _opts),
    do: Http.invalid_response(:deepseek, @url, body)

  defp hits({:error, _reason} = error, _opts), do: error

  defp wanted?(result, opts),
    do:
      at_least?(result["rerank_score"], Keyword.get(opts, :min_rerank_score)) and
        at_least?(result["authority"], Keyword.get(opts, :min_authority))

  defp at_least?(_value, nil = _floor), do: true
  defp at_least?(value, floor) when is_number(value), do: value >= floor
  defp at_least?(_missing, _floor), do: false

  defp hit(%{"url" => url} = result) do
    %Hit{
      url: url,
      title: result["title"],
      description: presence(result["summary"]) || presence(result["snippet"]),
      content: presence(result["content"]),
      published_at: result["date"],
      provider: :deepseek,
      metadata: %{
        snippet: presence(result["snippet"]),
        rerank_score: result["rerank_score"],
        authority: result["authority"],
        site_name: result["site_name"],
        site_icon: result["site_icon"]
      }
    }
  end
end
