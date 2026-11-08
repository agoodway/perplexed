defmodule Perplexed.VerdictTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Fixtures, Verdict}

  describe "judge/2" do
    test "readable text is ok" do
      assert Verdict.judge(Fixtures.readable_text()) == :ok
    end

    test "a short page with no other signal is thin" do
      assert Verdict.judge("Home | Contact") == :thin
    end

    test "a short bot challenge page is a challenge" do
      assert Verdict.judge("Just a moment...", "<title>Just a moment...</title>") == :challenge
    end

    test "a CDN block page rendered by a browser is a challenge" do
      text = """
      # 403 ERROR

      ## The request could not be satisfied.

      Request blocked. We can't connect to the server for this app or website at this time.
      There might be too much traffic or a configuration error. Try again later, or contact
      the app or website owner. If you provide content to customers through CloudFront, you
      can find steps to troubleshoot and help prevent this error by reviewing the docs.
      """

      assert Verdict.judge(text) == :challenge
    end

    test "a short page whose markup is an app root is a JavaScript shell" do
      assert Verdict.judge("Loading", ~s(<div id="root"></div><script src="/app.js"></script>)) ==
               :js_shell
    end

    test "a long article that mentions a captcha is still ok" do
      text = Fixtures.readable_text() <> " Some forms use a captcha. " <> Fixtures.readable_text()
      assert Verdict.judge(text) == :ok
    end
  end
end
