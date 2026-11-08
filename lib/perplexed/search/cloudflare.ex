defmodule Perplexed.Search.Cloudflare do
  @moduledoc """
  Cloudflare Web Search API (through AI Gateway) as a `Perplexed.Search` provider.

  One endpoint fronts three upstream engines, chosen with `:provider`:
  `"ceramic"` (Cloudflare's default upstream, long page descriptions),
  `"linkup"` (fast raw results) and `"exa"` (auto mode, page highlights).
  Requests bill at each engine's list price through AI Gateway credits, or
  to a provider key stored on the gateway. At most ten results per request.

  Needs `config :perplexed, cloudflare_account_id:` and a
  `cloudflare_api_token:` with Workers AI Read and AI Gateway Read;
  `cloudflare_gateway_id:` defaults to `"default"`.
  """

  @behaviour Perplexed.Search

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.{Config, Http}
  alias Perplexed.Search.Hit

  @base_url "https://api.cloudflare.com/client/v4/accounts"
  @default_limit 8
  @max_limit 10
  @max_query_length 1_024
  @timeout_ms 20_000
  @provider_names %{"ceramic" => :ceramic, "linkup" => :linkup, "exa" => :cloudflare_exa}
  @prices %{"ceramic" => 0.00025, "linkup" => 0.005, "exa" => 0.007}

  @impl true
  def price(opts), do: Map.get(@prices, Keyword.get(opts, :provider, "ceramic"), 0.0)

  @impl true
  def search(query, opts) when is_present(query) do
    upstream = Keyword.get(opts, :provider, "ceramic")

    with {:ok, name} <- upstream_name(upstream),
         {:ok, account_id} <- Config.credential(:cloudflare_account_id, name, opts),
         {:ok, token} <- Config.credential(:cloudflare_api_token, name, opts) do
      url = "#{@base_url}/#{account_id}/ai/websearch/"

      name
      |> Http.post_json(url, body(query, upstream, opts), token,
        receive_timeout: @timeout_ms,
        req_options: Keyword.get(opts, :req_options, [])
      )
      |> hits(name, url)
    end
  end

  def search(_query, _opts), do: {:error, {:invalid_request, %{reason: :empty_query}}}

  defp upstream_name(upstream) when is_map_key(@provider_names, upstream),
    do: {:ok, Map.fetch!(@provider_names, upstream)}

  defp upstream_name(upstream),
    do: {:error, {:invalid_request, %{reason: {:unknown_upstream, upstream}}}}

  defp body(query, upstream, opts) do
    %{
      "query" => query |> String.trim() |> String.slice(0, @max_query_length),
      "provider" => upstream,
      "limit" => opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit),
      "options" => %{"gateway" => %{"id" => gateway_id(opts)}}
    }
  end

  defp gateway_id(opts),
    do:
      Keyword.get_lazy(opts, :cloudflare_gateway_id, fn ->
        Config.get(:cloudflare_gateway_id, "default")
      end)

  # The REST envelope wraps the documented `items` payload in `result`.
  defp hits({:ok, %Req.Response{body: %{"result" => %{"items" => items}}}}, name, _url)
       when is_list(items),
       do: {:ok, hits(items, name)}

  defp hits({:ok, %Req.Response{body: %{"items" => items}}}, name, _url) when is_list(items),
    do: {:ok, hits(items, name)}

  defp hits({:ok, %Req.Response{body: body}}, name, url),
    do: Http.invalid_response(name, url, body)

  defp hits({:error, _reason} = error, _name, _url), do: error

  defp hits(items, name),
    do: items |> Enum.filter(&is_present(&1["url"])) |> Enum.map(&hit(&1, name))

  defp hit(%{"url" => url} = item, name),
    do: %Hit{url: url, title: item["title"], description: item["description"], provider: name}
end
