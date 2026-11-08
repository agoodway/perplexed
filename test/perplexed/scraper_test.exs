defmodule Perplexed.ScraperTest do
  use ExUnit.Case, async: true

  alias Perplexed.Scraper

  describe "time_left/2" do
    test "is the default when there is no deadline" do
      assert Scraper.time_left([], 60_000) == 60_000
    end

    test "is capped by the time left before the deadline" do
      deadline = System.monotonic_time(:millisecond) + 5_000
      left = Scraper.time_left([deadline: deadline], 60_000)

      assert left > 0 and left <= 5_000
    end

    test "never exceeds the default" do
      deadline = System.monotonic_time(:millisecond) + 120_000
      assert Scraper.time_left([deadline: deadline], 60_000) == 60_000
    end

    test "is at least 1 once the deadline has passed" do
      deadline = System.monotonic_time(:millisecond) - 1_000
      assert Scraper.time_left([deadline: deadline], 60_000) == 1
    end
  end
end
