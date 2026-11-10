defmodule Perplexed.Clock do
  @moduledoc false
  # Monotonic milliseconds for timing calls and enforcing deadlines. A
  # deadline is a monotonic millisecond time; `nil` means none.

  @doc "The current monotonic time in ms."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  @doc "Milliseconds since `started` (a `now_ms/0` reading)."
  @spec elapsed_ms(integer()) :: non_neg_integer()
  def elapsed_ms(started), do: now_ms() - started

  @doc "Runs `fun`, returning `{result, elapsed_ms}`."
  @spec timed((-> result)) :: {result, non_neg_integer()} when result: term()
  def timed(fun) do
    started = now_ms()
    result = fun.()
    {result, elapsed_ms(started)}
  end

  @doc "The deadline `timeout_ms` from now."
  @spec deadline(non_neg_integer()) :: integer()
  def deadline(timeout_ms), do: now_ms() + timeout_ms

  @doc "Whether `deadline` has passed; never for `nil`."
  @spec past?(integer() | nil) :: boolean()
  def past?(nil), do: false
  def past?(deadline), do: now_ms() >= deadline

  @doc "Milliseconds left before `deadline` (negative once past)."
  @spec left_ms(integer()) :: integer()
  def left_ms(deadline), do: deadline - now_ms()
end
