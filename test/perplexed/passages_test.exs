defmodule Perplexed.PassagesTest do
  use ExUnit.Case, async: true

  alias Perplexed.Passages

  defp filler(n),
    do: Enum.map_join(1..n, "\n\n", &"Paragraph #{&1} covers general administration and fees.")

  describe "select/3" do
    test "returns a page within the budget unchanged" do
      text = "Short page about opening hours."
      assert Passages.select(text, ["opening hours"], 1_000) == text
    end

    test "picks the passages that match the query terms from deep in a long page" do
      deep = "## Section 11-4 Winter schedule\n\nThe museum closes at four in winter months."
      text = Enum.join(["# Visitor handbook", filler(200), deep, filler(200)], "\n\n")

      selected = Passages.select(text, ["museum winter schedule closes"], 1_500)

      assert String.length(selected) <= 1_500
      assert selected =~ "The museum closes at four in winter months."
    end

    test "keeps the page opening for context and the chosen passages in page order" do
      first = "# Visitor handbook\n\nThe guide to visiting."
      early = "Tickets for the winter schedule go on sale in May."
      late = "The museum closes at four in winter months."
      text = Enum.join([first, filler(150), early, filler(150), late, filler(150)], "\n\n")

      selected = Passages.select(text, ["winter schedule museum closes"], 2_000)

      assert String.starts_with?(selected, "# Visitor handbook")
      {early_at, _} = :binary.match(selected, early)
      {late_at, _} = :binary.match(selected, late)
      assert early_at < late_at
    end

    test "matches terms case-insensitively and ignores stopwords" do
      text =
        Enum.join(
          ["Intro.", filler(200), "ROOM42 is the quiet reading room.", filler(200)],
          "\n\n"
        )

      assert Passages.select(text, ["Where is Room42?"], 800) =~
               "ROOM42 is the quiet reading room."
    end

    test "tolerates text that is not valid UTF-8" do
      text =
        Enum.join(
          ["Intro " <> <<0xFF>>, filler(200), "The museum winter schedule.", filler(200)],
          "\n\n"
        )

      selected = Passages.select(text, ["winter schedule"], 800)
      assert String.valid?(selected)
      assert selected =~ "winter schedule"
    end

    test "falls back to the page opening when no passage matches" do
      text = Enum.join(["# Opening line", filler(300)], "\n\n")
      selected = Passages.select(text, ["zebra quantum"], 500)

      assert String.starts_with?(selected, "# Opening line")
      assert String.length(selected) <= 500
    end
  end
end
