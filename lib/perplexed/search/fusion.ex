defmodule Perplexed.Search.Fusion do
  @moduledoc """
  Merges ranked hit lists from several sources (SearXNG instances, search
  engines) into one list: de-duplicates by normalized URL, scores by
  reciprocal rank, boosts hits several engines agree on, and demotes hits
  that share no terms with the query.

  For each merged hit:

    * **rank** - the sum over the lists it appears in of
      `1 / (k + position)`, position counted from 1. `k: 60` is Reciprocal
      Rank Fusion (Cormack, Clarke and Büttcher, 2009); `k: 0` is the plain
      `1 / position` sum metasearch2 uses, which favors the top few spots
      more strongly.
    * **agreement** - `1 + engine_boost * (distinct engines - 1)`, so a page
      that Bing, Brave and DuckDuckGo all return outranks one only Bing
      returned at the same position.
    * **lexical** - `(1 - lexical_weight) + lexical_weight * coverage`, where
      coverage is the share of the query's terms found in the hit's title,
      URL and description. An engine that answers a blocked client with
      unrelated pages (Bing does) gets those pages pushed down rather than
      trusted.

  The score is `rank * agreement * lexical`. Duplicates keep the title of
  their best-placed copy, the longest description, and every engine.
  """

  alias Perplexed.Search.Hit

  @default_k 60
  @default_engine_boost 0.15
  @default_lexical_weight 0.5

  # Tracking and session parameters that never change what a page shows.
  @tracking_params ~w(fbclid gclid gclsrc dclid msclkid yclid igshid mc_cid mc_eid
                      _ga _gl ref ref_src spm si srsltid)
  @stopwords ~w(a an and are as at be by for from how in is it of on or the to vs
                what when where which who why with)

  @type option ::
          {:k, non_neg_integer()}
          | {:engine_boost, number()}
          | {:lexical_weight, number()}
          | {:query, String.t()}
          | {:limit, pos_integer()}

  @doc """
  Fuses `lists` (each a list of hits, best first) into one ranked list.

  ## Options

    * `:query` - the search query, for the lexical factor; without it
      coverage counts as full.
    * `:k` - the reciprocal rank constant, default #{@default_k}.
    * `:engine_boost` - weight of each extra agreeing engine, default
      #{@default_engine_boost}.
    * `:lexical_weight` - 0 ignores query terms, 1 scores a hit with none of
      them at zero; default #{@default_lexical_weight}.
    * `:limit` - hits to return, default all.
  """
  @spec fuse([[Hit.t()]], [option()]) :: [Hit.t()]
  def fuse(lists, opts \\ []) when is_list(lists) do
    k = Keyword.get(opts, :k, @default_k)
    terms = opts |> Keyword.get(:query, "") |> terms()

    lists
    |> Enum.flat_map(&ranked_entries(&1, k))
    |> Enum.group_by(& &1.key)
    |> Map.values()
    |> Enum.map(&merge/1)
    |> Enum.map(&score(&1, terms, opts))
    |> Enum.sort_by(fn {score, first_seen, _hit} -> {-score, first_seen} end)
    |> Enum.map(fn {_score, _first_seen, hit} -> hit end)
    |> limited(Keyword.get(opts, :limit))
  end

  # A list's hits, de-duplicated within the list (first copy wins), with
  # their reciprocal rank contribution.
  defp ranked_entries(hits, k) do
    hits
    |> Enum.uniq_by(&url_key(&1.url))
    |> Enum.with_index(1)
    |> Enum.map(fn {hit, position} ->
      %{key: url_key(hit.url), hit: hit, position: position, rank: 1 / (k + position)}
    end)
  end

  defp merge(entries) do
    [best | _rest] = Enum.sort_by(entries, & &1.position)

    hit = %{
      best.hit
      | description: entries |> Enum.map(& &1.hit.description) |> longest(),
        engines: entries |> Enum.flat_map(&(&1.hit.engines || [])) |> Enum.uniq()
    }

    %{hit: hit, rank: entries |> Enum.map(& &1.rank) |> Enum.sum(), first_seen: best.position}
  end

  defp score(%{hit: hit, rank: rank, first_seen: first_seen}, terms, opts) do
    boost = Keyword.get(opts, :engine_boost, @default_engine_boost)
    weight = Keyword.get(opts, :lexical_weight, @default_lexical_weight)
    agreement = 1 + boost * max(length(hit.engines) - 1, 0)
    lexical = 1 - weight + weight * coverage(hit, terms)
    {rank * agreement * lexical, first_seen, hit}
  end

  @doc """
  The share of `query`'s terms (lowercased words, stopwords dropped) that
  appear in the hit's title, URL or description: 1.0 when the query has no
  terms.
  """
  @spec coverage(Hit.t(), String.t() | MapSet.t()) :: float()
  def coverage(hit, query) when is_binary(query), do: coverage(hit, terms(query))

  def coverage(%Hit{} = hit, %MapSet{} = terms), do: covered(hit, terms, MapSet.size(terms))

  defp covered(_hit, _terms, 0), do: 1.0

  defp covered(%Hit{title: title, url: url, description: description}, terms, size) do
    found = [title, url, description] |> Enum.join(" ") |> terms()
    MapSet.size(MapSet.intersection(terms, found)) / size
  end

  @doc """
  The mean `coverage/2` of `hits`' first `depth` (default 5): how much of
  the query a result list talks about. 0.0 for no hits.
  """
  @spec mean_coverage([Hit.t()], String.t(), pos_integer()) :: float()
  def mean_coverage(hits, query, depth \\ 5)
  def mean_coverage([], _query, _depth), do: 0.0

  def mean_coverage(hits, query, depth) do
    top = Enum.take(hits, depth)
    terms = terms(query)
    Enum.sum_by(top, &coverage(&1, terms)) / length(top)
  end

  defp terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> MapSet.new()
  end

  defp longest(descriptions),
    do: descriptions |> Enum.reject(&is_nil/1) |> Enum.max_by(&String.length/1, fn -> nil end)

  defp limited(hits, nil), do: hits
  defp limited(hits, limit), do: Enum.take(hits, limit)

  @doc """
  The de-duplication key for `url`: scheme-less, lowercase host without
  `www.`, no fragment, no trailing slash, tracking parameters (`utm_*`,
  `fbclid`, `gclid`, ...) removed and the rest sorted.

      iex> Perplexed.Search.Fusion.url_key("https://www.Example.com/a/?utm_source=x&b=2&a=1#top")
      "example.com/a?a=1&b=2"
  """
  @spec url_key(String.t()) :: String.t()
  def url_key(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))
    host = (uri.host || "") |> String.downcase() |> String.replace_prefix("www.", "")
    path = (uri.path || "") |> String.trim_trailing("/")
    host <> path <> query_key(uri.query)
  end

  defp query_key(nil), do: ""

  defp query_key(query) do
    query
    |> URI.query_decoder()
    |> Enum.reject(fn {name, _value} -> tracking?(String.downcase(name)) end)
    |> Enum.sort()
    |> encoded_query()
  end

  defp encoded_query([]), do: ""
  defp encoded_query(params), do: "?" <> URI.encode_query(params)

  defp tracking?("utm_" <> _rest), do: true
  defp tracking?(name), do: name in @tracking_params
end
