defmodule Perplexed.Scraper.ImpersonatedTest do
  use ExUnit.Case, async: true

  alias Perplexed.Scraper.Impersonated

  describe "retries?/1" do
    test "is worth trying after a refusal, challenge, status error or transport failure" do
      for outcome <- [
            :blocked,
            :challenge,
            :http_error,
            :download_failed,
            :timeout,
            :tls_chain_error
          ] do
        assert Impersonated.retries?(outcome), inspect(outcome)
      end
    end

    test "is not worth trying after a JavaScript shell, a missing page or an unusable file" do
      for outcome <- [
            :needs_js,
            :js_shell,
            :not_found,
            :unsupported,
            :too_large,
            :conversion_failed,
            :too_many_redirects,
            :unreadable
          ] do
        refute Impersonated.retries?(outcome), inspect(outcome)
      end
    end
  end
end
