defmodule Perplexed.Verdict do
  @moduledoc """
  Judges whether fetched page text is worth handing to a model.

  An HTTP 200 alone is not success. A bot challenge, a JavaScript shell that
  renders nothing without a browser, or a page with almost no readable text
  all come back as 200s. The fetch ladder uses the verdict to decide which
  tier to try next: a challenge is worth an impersonated retry, while a
  JavaScript shell needs a real browser.

  Markup markers that only a challenge page carries (`cf-chl-`,
  `challenge-platform`) count on any page under 4,000 characters. Phrases a
  real page could also contain ("captcha", "access denied") count only on a
  page with almost no readable text, so an article that mentions a captcha
  is not mistaken for a challenge.
  """

  @type t :: :ok | :challenge | :js_shell | :thin

  @min_readable_chars 400
  @markup_scan_max_chars 4_000
  @phrase_scan_max_chars 1_000

  @challenge_markup [
    "cf-chl-",
    "challenge-platform",
    "_incapsula_resource",
    "px-captcha",
    "attention required! | cloudflare"
  ]

  @challenge_phrases [
    "just a moment...",
    "verify you are human",
    "checking your browser",
    "captcha",
    "access denied",
    "request unsuccessful. incapsula",
    "pardon our interruption",
    "enable javascript and cookies to continue",
    "request blocked",
    "the request could not be satisfied",
    "you have been blocked",
    "access to this page has been denied",
    "403 forbidden",
    "403 error",
    "error 1020"
  ]

  @js_shell_markers [
    ~s(id="root"),
    ~s(id="app"),
    ~s(id="__next"),
    "ng-app",
    "please enable javascript",
    "you need to enable javascript",
    "requires javascript"
  ]

  @doc """
  The verdict for a page's readable `text`, using `raw` (the undecoded HTML,
  when there was any) to tell a challenge or JavaScript shell from a page
  that is merely short.
  """
  @spec judge(String.t(), String.t() | nil) :: t()
  def judge(text, raw \\ nil) when is_binary(text) do
    readable = String.trim(text)
    length = String.length(readable)
    short? = length < @min_readable_chars
    scan = scan_text(readable, raw)

    cond do
      length <= @markup_scan_max_chars and
          Enum.any?(@challenge_markup, &String.contains?(scan, &1)) ->
        :challenge

      length <= @phrase_scan_max_chars and
          Enum.any?(@challenge_phrases, &String.contains?(scan, &1)) ->
        :challenge

      short? and Enum.any?(@js_shell_markers, &String.contains?(scan, &1)) ->
        :js_shell

      short? ->
        :thin

      true ->
        :ok
    end
  end

  defp scan_text(readable, raw) when is_binary(raw),
    do: String.downcase(readable <> "\n" <> String.slice(raw, 0, 20_000))

  defp scan_text(readable, _raw), do: String.downcase(readable)
end
