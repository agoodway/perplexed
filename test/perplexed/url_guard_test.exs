defmodule Perplexed.UrlGuardTest do
  use ExUnit.Case, async: true

  alias Perplexed.{Fixtures, UrlGuard}

  describe "validate/1" do
    test "allows a public address" do
      assert UrlGuard.validate("http://93.184.215.14/guide") ==
               {:ok, "http://93.184.215.14/guide"}
    end

    test "refuses loopback, private and link-local addresses" do
      for url <- [
            "http://127.0.0.1/",
            "http://10.1.2.3/",
            "http://192.168.1.1/",
            "http://169.254.169.254/"
          ] do
        assert UrlGuard.validate(url) == {:error, :private_address}, url
      end
    end

    test "refuses other schemes, embedded credentials and blank input" do
      assert UrlGuard.validate("ftp://93.184.215.14/file") == {:error, :invalid_url}
      assert UrlGuard.validate("http://user:pass@93.184.215.14/") == {:error, :invalid_url}
      assert UrlGuard.validate("") == {:error, :invalid_url}
    end
  end

  describe "private?/1" do
    test "covers IPv6 loopback, unique-local and IPv4-mapped private addresses" do
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0, 0x7F00, 0x0001})
      assert UrlGuard.private?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
      assert UrlGuard.private?({0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 0})
      refute UrlGuard.private?({0x2002, 0x5DB8, 0xD70E, 0, 0, 0, 0, 0})
      assert UrlGuard.private?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0x2001, 0x0000, 0x4136, 0xE378, 0x8000, 0x63BF, 0x3FFF, 0xFDD2})
      refute UrlGuard.private?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
    end
  end

  describe "validate/1 hosts" do
    test "refuses localhost" do
      assert UrlGuard.validate("http://localhost/") == {:error, :private_address}
    end

    test "refuses the IPv6 loopback literal" do
      assert UrlGuard.validate("http://[::1]/") == {:error, :private_address}
    end

    test "refuses a host that does not resolve" do
      assert UrlGuard.validate("http://nothing.invalid/") == {:error, :unresolvable_host}
    end

    test "refuses a non-binary URL" do
      assert UrlGuard.validate(nil) == {:error, :invalid_url}
    end
  end

  describe "private?/1 IPv4 boundaries" do
    test "carrier-grade NAT starts at 100.64" do
      refute UrlGuard.private?({100, 63, 255, 255})
      assert UrlGuard.private?({100, 64, 0, 0})
      assert UrlGuard.private?({100, 127, 255, 255})
      refute UrlGuard.private?({100, 128, 0, 0})
    end

    test "172.16.0.0/12 spans 172.16 to 172.31" do
      refute UrlGuard.private?({172, 15, 0, 1})
      assert UrlGuard.private?({172, 16, 0, 1})
      assert UrlGuard.private?({172, 31, 255, 255})
      refute UrlGuard.private?({172, 32, 0, 1})
    end

    test "benchmarking range is 198.18 and 198.19" do
      refute UrlGuard.private?({198, 17, 0, 1})
      assert UrlGuard.private?({198, 18, 0, 1})
      assert UrlGuard.private?({198, 19, 255, 255})
      refute UrlGuard.private?({198, 20, 0, 1})
    end

    test "multicast and reserved space starts at 224" do
      refute UrlGuard.private?({223, 255, 255, 255})
      assert UrlGuard.private?({224, 0, 0, 1})
      assert UrlGuard.private?({255, 255, 255, 255})
    end

    test "192.0.0.0/24 is reserved but its neighbours are not" do
      assert UrlGuard.private?({192, 0, 0, 1})
      assert UrlGuard.private?({192, 0, 0, 255})
      refute UrlGuard.private?({192, 0, 1, 1})
      refute UrlGuard.private?({192, 169, 0, 1})
      assert UrlGuard.private?({192, 168, 0, 1})
    end

    test "this-network, 10/8, loopback and link-local are private" do
      assert UrlGuard.private?({0, 1, 2, 3})
      assert UrlGuard.private?({10, 255, 255, 255})
      assert UrlGuard.private?({127, 8, 8, 8})
      assert UrlGuard.private?({169, 254, 0, 1})
      refute UrlGuard.private?({169, 253, 0, 1})
    end

    test "ordinary public addresses are allowed" do
      refute UrlGuard.private?({93, 184, 215, 14})
      refute UrlGuard.private?({8, 8, 8, 8})
    end
  end

  describe "private?/1 IPv6 ranges" do
    test "link-local, site-local and multicast prefixes" do
      assert UrlGuard.private?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
    end

    test "unique-local covers fc00::/7 only" do
      assert UrlGuard.private?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert UrlGuard.private?({0xFDFF, 0, 0, 0, 0, 0, 0, 1})
      refute UrlGuard.private?({0xFBFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "the unspecified and loopback addresses are private" do
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0, 0, 0})
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "NAT64 wraps the IPv4 verdict" do
      assert UrlGuard.private?({0x0064, 0xFF9B, 0, 0, 0, 0, 0xC0A8, 0x0101})
      refute UrlGuard.private?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x5DB8, 0xD70E})
    end

    test "6to4 wraps the IPv4 verdict" do
      assert UrlGuard.private?({0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1})
      refute UrlGuard.private?({0x2002, 0x5DB8, 0xD70E, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped addresses wrap the IPv4 verdict" do
      assert UrlGuard.private?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
      refute UrlGuard.private?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD70E})
    end
  end

  describe "check/2" do
    def validator(url, marker, test_pid) do
      send(test_pid, {:validated, url, marker})
      verdict(url)
    end

    defp verdict("https://example.org/blocked" <> _rest), do: {:error, :custom_refusal}
    defp verdict(url), do: {:ok, url}

    test "calls a custom validator with the extra arguments" do
      opts = [url_validator: {__MODULE__, :validator, [:marker, self()]}]

      assert UrlGuard.check("https://example.org/page", opts) == {:ok, "https://example.org/page"}
      assert_received {:validated, "https://example.org/page", :marker}
    end

    test "passes through the custom validator's error" do
      opts = [url_validator: {__MODULE__, :validator, [:marker, self()]}]

      assert UrlGuard.check("https://example.org/blocked", opts) == {:error, :custom_refusal}
    end

    test "a per-call validator replaces the built-in check" do
      opts = [url_validator: {Fixtures, :allow_url, []}]
      assert UrlGuard.check("http://127.0.0.1/", opts) == {:ok, "http://127.0.0.1/"}
    end
  end
end
