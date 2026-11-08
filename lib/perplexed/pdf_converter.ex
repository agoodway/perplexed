defmodule Perplexed.PdfConverter do
  @moduledoc """
  The behaviour that turns PDF bytes into Markdown for a scrape.

  Configure an implementation with `config :perplexed, pdf_converter:
  Module`. Without one, PDF pages scrape as `{:error, :unsupported}`.

  Failure atoms that mean no other scraper can help (`:needs_ocr`,
  `:encrypted`, `:unsupported`) end the scrape ladder.
  """

  alias Perplexed.Config

  @doc "Converts PDF `binary` (fetched from a URL ending in `filename`) to Markdown."
  @callback convert(binary(), filename :: String.t()) :: {:ok, String.t()} | {:error, atom()}

  @doc """
  Converts `binary` with `opts[:pdf_converter]`, else the configured
  converter.
  """
  @spec convert(binary(), String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def convert(binary, filename, opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get_lazy(:pdf_converter, fn -> Config.get(:pdf_converter) end)
    |> convert_with(binary, filename)
  end

  defp convert_with(nil, _binary, _filename), do: {:error, :unsupported}
  defp convert_with(module, binary, filename), do: module.convert(binary, filename)
end
