defmodule Perplexed.Config do
  @moduledoc """
  Perplexed's settings.

  A host passes them when it starts Perplexed, `{Perplexed, settings}` in its
  supervision tree; they are kept in `:persistent_term`. A setting not given
  there falls back to `config :perplexed`, so a standalone project can use
  ordinary application config.

  | Key                      | Used by                                      |
  | ------------------------ | -------------------------------------------- |
  | `:model`                 | `Perplexed.answer/2` default model           |
  | `:provider`              | Default search provider spec                 |
  | `:ladder`                | Default scrape ladder                        |
  | `:prices`                | Search price overrides, by provider spec     |
  | `:cloudflare_account_id` | Cloudflare search, Browser Run               |
  | `:cloudflare_api_token`  | Cloudflare search, Browser Run               |
  | `:cloudflare_gateway_id` | Cloudflare search (default `"default"`)      |
  | `:deepseek_api_key`      | DeepSeek search and scrape                   |
  | `:firecrawl_api_key`     | Firecrawl search and scrape                  |
  | `:firecrawl_credit_usd`  | Firecrawl cost per credit (your plan)        |
  | `:firecrawl_pdf`         | Let Firecrawl read PDFs the ladder could not |
  | `:searxng_instances`     | SearXNG search: base URLs, or `:auto`        |
  | `:searxng_discovery`     | `:auto` discovery filters (`countries:`)     |
  | `:searxng_refresh_ms`    | `:auto` refresh interval (default daily)     |
  | `:pdf_converter`         | `Perplexed.PdfConverter` implementation      |
  | `:url_validator`         | `Perplexed.UrlGuard` override                |
  """

  import Perplexed.Guards, only: [is_present: 1]

  @key {__MODULE__, :settings}

  @doc false
  @spec put(keyword()) :: :ok
  def put(settings) when is_list(settings), do: :persistent_term.put(@key, settings)

  @doc false
  @spec erase() :: :ok
  def erase do
    :persistent_term.erase(@key)
    :ok
  end

  @doc "The started settings."
  @spec all() :: keyword()
  def all, do: :persistent_term.get(@key, [])

  @doc "The setting for `key`, or `default` when unset."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key),
    do: Keyword.get_lazy(all(), key, fn -> Application.get_env(:perplexed, key, default) end)

  @doc """
  A credential for `provider`: the call's `opts[:credentials][key]` when
  given, else the setting. `{:ok, value}`, or an `:authentication` error
  naming the missing key when it is unset or blank.
  """
  @spec credential(atom(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, {:authentication, map()}}
  def credential(key, provider, opts \\ []) when is_atom(key) do
    opts
    |> Keyword.get(:credentials, [])
    |> Keyword.get_lazy(key, fn -> get(key) end)
    |> present(key, provider)
  end

  @doc "Whether every key in `keys` has a credential for `provider` (see `credential/3`)."
  @spec credentials?(atom() | [atom()], atom(), keyword()) :: boolean()
  def credentials?(keys, provider, opts \\ []),
    do: keys |> List.wrap() |> Enum.all?(&match?({:ok, _value}, credential(&1, provider, opts)))

  defp present(value, _key, _provider) when is_present(value), do: {:ok, value}

  defp present(_blank, key, provider),
    do: {:error, {:authentication, %{provider: provider, reason: {:missing, key}}}}
end
