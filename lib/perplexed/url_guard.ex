defmodule Perplexed.UrlGuard do
  @moduledoc """
  Refuses URLs that would point a scrape at a private network.

  Perplexed scrapes URLs a model or a search engine chose, so every request
  and redirect target is checked here first. The default check allows only
  `http`/`https` URLs without credentials whose host resolves only to public
  addresses.

  A host application can replace the check with `url_validator:
  {Module, :fun, extra_args}`, per call (in the options) or in the settings;
  it is called as `Module.fun(url, ...extra_args)` and must answer
  `{:ok, url}` or `{:error, reason}`.

  DNS is resolved here and again by the HTTP client, so a host that changes
  its answer between the two (DNS rebinding) is not caught.
  """

  import Perplexed.Guards, only: [is_present: 1]

  alias Perplexed.Config

  @doc """
  `{:ok, url}` when `url` is safe to fetch, otherwise `{:error, reason}`.
  Uses `opts[:url_validator]`, else the configured one, else `validate/1`.
  """
  @spec check(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def check(url, opts \\ []),
    do:
      opts
      |> Keyword.get_lazy(:url_validator, fn -> Config.get(:url_validator) end)
      |> run_check(url)

  defp run_check({module, fun, args}, url), do: apply(module, fun, [url | args])
  defp run_check(nil, url), do: validate(url)

  @doc "The built-in check, used when no `:url_validator` is configured."
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate(url) when is_present(url) do
    with %URI{scheme: scheme, host: host, userinfo: nil}
         when scheme in ["http", "https"] and is_present(host) <- URI.parse(url),
         {:ok, addresses} <- resolve(host),
         :ok <- addresses |> Enum.any?(&private?/1) |> public?() do
      {:ok, url}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_url}
    end
  end

  def validate(_url), do: {:error, :invalid_url}

  defp resolve(host) do
    charlist = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(&addresses(:inet.getaddrs(charlist, &1)))
    |> resolved()
  end

  defp resolved([]), do: {:error, :unresolvable_host}
  defp resolved(addresses), do: {:ok, addresses}

  defp public?(true), do: {:error, :private_address}
  defp public?(false), do: :ok

  defp addresses({:ok, addresses}), do: addresses
  defp addresses({:error, _reason}), do: []

  @doc "Whether an `:inet` address tuple is loopback, private, link-local or otherwise reserved."
  @spec private?(:inet.ip_address()) :: boolean()
  def private?({0, _, _, _}), do: true
  def private?({10, _, _, _}), do: true
  def private?({100, b, _, _}) when b in 64..127, do: true
  def private?({127, _, _, _}), do: true
  def private?({169, 254, _, _}), do: true
  def private?({172, b, _, _}) when b in 16..31, do: true
  def private?({192, 0, 0, _}), do: true
  def private?({192, 168, _, _}), do: true
  def private?({198, b, _, _}) when b in 18..19, do: true
  def private?({a, _, _, _}) when a >= 224, do: true
  def private?({0, 0, 0, 0, 0, 0, 0, a}) when a in 0..1, do: true
  # IPv6 forms that carry an IPv4 address: mapped, compatible, NAT64, 6to4.
  def private?({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: private?(ipv4(a, b))
  def private?({0, 0, 0, 0, 0, 0, a, b}), do: private?(ipv4(a, b))
  def private?({0x0064, 0xFF9B, 0, 0, 0, 0, a, b}), do: private?(ipv4(a, b))
  def private?({0x2002, a, b, _, _, _, _, _}), do: private?(ipv4(a, b))
  def private?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  # Link-local fe80::/10 and the deprecated site-local fec0::/10.
  def private?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEFF, do: true
  # Teredo tunnels (2001::/32) can relay to arbitrary IPv4 hosts.
  def private?({0x2001, 0x0000, _, _, _, _, _, _}), do: true
  def private?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: true
  def private?(_address), do: false

  defp ipv4(high, low), do: {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}
end
