defmodule Perplexed.Verdict do
  @moduledoc """
  Judges whether fetched page text is worth handing to a model.

  An HTTP 200 alone is not success. A bot challenge, a JavaScript shell that
  renders nothing without a browser, or a page with almost no readable text
  all come back as 200s. The fetch ladder uses the verdict to decide which
  tier to try next: a challenge is worth an impersonated retry, while a
  JavaScript shell needs a real browser.

  Markup markers that only a challenge page carries (such as `cf-chl-` and
  `challenge-platform`) count on any page of at most 4,000 characters.
  Phrases a real page could also contain ("captcha", "access denied") count
  only on a page of at most 1,000 characters, so an article that mentions a
  captcha is not mistaken for a challenge. A page of at most 1,500 characters that
  says it is behind a sign-in or subscription ("sign in to continue",
  "subscribe to continue reading"), or a near-empty page holding a
  password field, is a `:login_wall`; a prompt to sign in to comment is not.
  Like a JavaScript shell, a login wall skips the impersonated rung: a
  browser fingerprint does not sign in.
  """

  @type t :: :ok | :challenge | :login_wall | :js_shell | :thin

  @min_readable_chars 400
  @markup_scan_max_chars 4_000
  @phrase_scan_max_chars 1_000
  # A sign-in or subscribe wall leaves a little teaser text, so it is looked
  # for on pages up to this long.
  @wall_scan_max_chars 1_500

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

  @password_markup [
    ~s(type="password"),
    ~s(type='password'),
    "type=password",
    ~s(autocomplete="current-password")
  ]

  # Only phrases that put the page itself behind the wall: "sign in to
  # comment" sits under real articles and does not count.
  @login_wall_phrases [
    "sign in to continue",
    "log in to continue",
    "login to continue",
    "sign in to view this",
    "log in to view this",
    "create a free account to continue",
    "subscribe to continue reading",
    "to continue reading, subscribe",
    "this content is for subscribers",
    "already a subscriber? sign in"
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

  # Checked in order; the first rule whose length limit the page is within
  # and whose markers it contains decides. A page shorter than
  # @min_readable_chars that matches nothing else is thin.
  @short_max @min_readable_chars - 1
  @rules [
    {:challenge, @markup_scan_max_chars, @challenge_markup},
    {:challenge, @phrase_scan_max_chars, @challenge_phrases},
    {:login_wall, @wall_scan_max_chars, @login_wall_phrases},
    {:js_shell, @short_max, @js_shell_markers},
    # A sign-in form on a page with almost nothing else on it; a login box
    # in the header of a real article does not count.
    {:login_wall, @short_max, @password_markup},
    {:thin, @short_max, :any}
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
    scan = scan_text(readable, raw)
    Enum.find_value(@rules, :ok, &verdict(&1, length, scan))
  end

  defp verdict({verdict, max_chars, markers}, length, scan) when length <= max_chars,
    do: matches?(markers, scan) && verdict

  defp verdict(_rule, _length, _scan), do: nil

  defp matches?(:any, _scan), do: true
  defp matches?(markers, scan), do: Enum.any?(markers, &String.contains?(scan, &1))

  defp scan_text(readable, raw) when is_binary(raw),
    do: String.downcase(readable <> "\n" <> String.slice(raw, 0, 20_000))

  defp scan_text(readable, _raw), do: String.downcase(readable)
end
