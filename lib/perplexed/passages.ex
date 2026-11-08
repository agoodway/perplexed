defmodule Perplexed.Passages do
  @moduledoc """
  Chooses which parts of a long page a model gets to read.

  A page within the budget passes through unchanged. A longer page keeps
  its opening, for context, then the chunks that best match the query terms,
  scored like BM25 (term frequency weighted by how rare the term is across
  the page's chunks), joined in page order with `[…]` between them. When no
  chunk matches, the page is cut to the budget from the top.
  """

  @lead_chars 400
  @min_chunk_chars 300
  @max_chunk_chars 1_200
  @separator "\n\n[…]\n\n"
  @separator_length String.length(@separator)
  @stopwords ~w(a an and are as at be by can do does for from has have how i in is
                it its of on or that the their this to was what when where which
                who why will with you your)

  @doc """
  Up to `budget` characters of `text`, favoring passages that match the
  terms in `queries` (the question and any search queries).
  """
  @spec select(String.t(), [String.t()], pos_integer()) :: String.t()
  def select(text, queries, budget) when is_binary(text) and is_list(queries) do
    text = String.replace_invalid(text)
    text |> String.length() |> within(text, queries, budget)
  end

  defp within(length, text, _queries, budget) when length <= budget, do: text
  defp within(_length, text, queries, budget), do: pick(text, terms(queries), budget)

  defp pick(text, terms, budget) do
    lead_length = min(@lead_chars, div(budget, 5))
    lead = String.slice(text, 0, lead_length)
    chunk_size = budget |> div(6) |> max(@min_chunk_chars) |> min(@max_chunk_chars)
    chunks = text |> String.slice(lead_length..-1//1) |> chunks(chunk_size)
    room = budget - String.length(lead) - @separator_length

    chunks |> ranked(terms) |> picked(text, lead, room, budget)
  end

  defp picked([], text, _lead, _room, budget), do: String.slice(text, 0, budget)
  defp picked(ranked, _text, lead, room, budget), do: join(lead, fit(ranked, room), budget)

  # `{index, chunk, cost}` for chunks with at least one matching term, best
  # first; `cost` is the characters the chunk takes with its separator.
  defp ranked(chunks, terms) do
    counts = Enum.map(chunks, fn {index, chunk} -> {index, chunk, frequencies(chunk)} end)
    idf = idf(counts, terms)

    counts
    |> Enum.map(fn {index, chunk, freq} -> {index, chunk, score(freq, terms, idf)} end)
    |> Enum.filter(fn {_index, _chunk, score} -> score > 0 end)
    |> Enum.sort_by(fn {index, _chunk, score} -> {-score, index} end)
    |> Enum.map(fn {index, chunk, _score} ->
      {index, chunk, String.length(chunk) + @separator_length}
    end)
  end

  defp fit(ranked, room) do
    ranked
    |> Enum.reduce({[], room}, &take/2)
    |> elem(0)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp take({index, chunk, cost}, {chosen, left}) when cost <= left,
    do: {[{index, chunk} | chosen], left - cost}

  defp take(_chunk, acc), do: acc

  defp join(lead, chosen, budget),
    do: [lead | chosen] |> Enum.join(@separator) |> String.slice(0, budget)

  # Paragraphs merged up to `size` characters; an oversized paragraph is cut.
  defp chunks(text, size) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.flat_map(&cut(&1, size))
    |> Enum.reduce([], &merge(&1, &2, size))
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} -> {index, chunk} end)
  end

  defp cut(paragraph, size) do
    paragraph
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  defp merge(paragraph, [current | rest], size) do
    if String.length(current) + String.length(paragraph) + 2 <= size,
      do: [current <> "\n\n" <> paragraph | rest],
      else: [paragraph, current | rest]
  end

  defp merge(paragraph, [], _size), do: [paragraph]

  defp terms(queries), do: queries |> Enum.flat_map(&tokens/1) |> Enum.uniq()

  defp tokens(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 2))
  end

  defp frequencies(chunk), do: chunk |> tokens() |> Enum.frequencies()

  defp idf(counts, terms) do
    total = length(counts)

    Map.new(terms, fn term ->
      df = Enum.count(counts, fn {_index, _chunk, freq} -> Map.has_key?(freq, term) end)
      {term, :math.log(1 + total / (1 + df))}
    end)
  end

  defp score(freq, terms, idf),
    do: freq |> Map.take(terms) |> Enum.reduce(0.0, &weighted(&1, &2, idf))

  defp weighted({term, tf}, acc, idf), do: acc + Map.fetch!(idf, term) * (1 + :math.log(tf))
end
