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

    test "a short page asking for a password or subscription is a login wall" do
      teaser = "Our analysis of the market. Subscribe to continue reading."
      assert Verdict.judge(teaser) == :login_wall

      form = ~s(<form><input name="email"><input type="password" name="pw"></form>)
      assert Verdict.judge("Sign in to your account", form) == :login_wall
    end

    test "a long article with a sign-in link is still ok" do
      article =
        String.duplicate("The council approved the zoning change after a long debate. ", 40)

      assert Verdict.judge(article <> " Please sign in to comment.") == :ok
    end

    test "a short article with a prompt to sign in to comment is ok" do
      article = String.duplicate("The council approved the zoning change. ", 25)
      assert String.length(article) in 400..1_500
      assert Verdict.judge(article <> " Please sign in to comment.") == :ok
    end

    test "a readable page with a login form in its header is ok" do
      article = String.duplicate("The council approved the zoning change. ", 25)
      header = ~s(<header><form><input name="user"><input type=password></form></header>)
      assert Verdict.judge(article, header <> "<main>" <> article <> "</main>") == :ok
    end

    test "a near-empty page with an unquoted password field is a login wall" do
      assert Verdict.judge("Members", "<form><input type=password></form>") == :login_wall
    end

    test "a JavaScript shell is a shell even with a password field" do
      assert Verdict.judge("", ~s(<div id="root"></div><input type="password">)) == :js_shell
    end

    test "a sign-in wall counts up to 1,500 characters of text" do
      wall = " Sign in to continue."
      filler = fn total -> String.duplicate("a", total - String.length(wall)) end

      assert Verdict.judge(filler.(1_500) <> wall) == :login_wall
      assert Verdict.judge(filler.(1_501) <> wall) == :ok
    end

    test "a challenge wins over a login wall" do
      assert Verdict.judge("Just a moment... sign in to continue") == :challenge
    end

    test "a long article that mentions a captcha is still ok" do
      text = Fixtures.readable_text() <> " Some forms use a captcha. " <> Fixtures.readable_text()
      assert Verdict.judge(text) == :ok
    end
  end
end
