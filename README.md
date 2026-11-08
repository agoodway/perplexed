# Perplexed

[![Hex.pm](https://img.shields.io/hexpm/v/perplexed.svg)](https://hex.pm/packages/perplexed)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/perplexed)
[![License](https://img.shields.io/hexpm/l/perplexed.svg)](https://github.com/agoodway/perplexed/blob/main/LICENSE)

A small Perplexity-style web search, scrape and answer toolkit for Elixir.

Perplexed searches the web through a provider you choose, reads the pages it
finds, and turns them into a cited answer on any model
[ReqLLM](https://hex.pm/packages/req_llm) supports.

- **Swappable search** - Firecrawl, Cloudflare Web Search (Ceramic, Linkup,
  Exa) and DeepSeek built in, or any module implementing `Perplexed.Search`.
- **Page reading** - fetches pages as Markdown, PDFs included, with hosted
  scrapers (Firecrawl, Cloudflare Browser Run) for pages that need a browser.
- **Cited answers** - plan, search, rank, read and summarize, returning the
  sources used and every result considered.
- **Cost and telemetry** - USD cost on every search, scrape and model call.

## Installation

```elixir
def deps do
  [
    {:perplexed, "~> 0.1.0"}
  ]
end
```

Start Perplexed in your supervision tree with the keys you use:

```elixir
children = [
  {Perplexed,
   firecrawl_api_key: System.fetch_env!("FIRECRAWL_API_KEY"),
   provider: :firecrawl,
   model: "anthropic:claude-haiku-4-5"}
]
```

`answer/2` also needs your model provider's key, configured the way ReqLLM
expects (for example `ANTHROPIC_API_KEY`).

### Native dependency

The impersonated scraper uses [cloaked_req](https://hex.pm/packages/cloaked_req),
a Rust NIF. It downloads a precompiled binary, so nothing else is needed, on:

- macOS on Apple Silicon (`aarch64-apple-darwin`)
- Linux x86_64 and aarch64 with glibc 2.34 or newer

On any other platform (for example Intel macOS or Alpine/musl), build it from
source:

1. Add `{:rustler, "~> 0.38.0"}` to your deps.
2. Install Rust 1.98 or newer, a C and C++ compiler, cmake, libclang and git.
3. Compile with `CLOAKED_REQ_BUILD=1` (on musl, also
   `RUSTFLAGS="-C target-feature=-crt-static"`).

cloaked_req is licensed LGPL-3.0-or-later.

### PDFs

Perplexed ships no PDF converter, so PDF pages scrape as `:unsupported` until
you configure one. Implement `Perplexed.PdfConverter` around the tool of your
choice, for example Firecrawl's [AnyDoc](https://github.com/firecrawl/anydoc)
Rust crate or poppler's `pdftotext`, and pass it as `pdf_converter:`:

```elixir
defmodule MyApp.PdfToText do
  @behaviour Perplexed.PdfConverter

  @impl true
  def convert(binary, _filename) do
    path = Path.join(System.tmp_dir!(), "perplexed-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, binary)
    result = System.cmd("pdftotext", ["-layout", path, "-"])
    File.rm(path)
    converted(result)
  end

  defp converted({text, 0}), do: {:ok, text}
  defp converted(_failed), do: {:error, :unsupported}
end
```

## Usage

```elixir
# Search, optionally reading each result's page
{:ok, result} = Perplexed.search("elixir release notes", scrape: true)
result.hits    #=> [%Perplexed.Search.Hit{url: ..., document: %Perplexed.Document{...}}, ...]
result.cost    #=> 0.00198

# Read one page as Markdown
{:ok, document} = Perplexed.scrape("https://example.com/guide")
document.markdown  #=> "# Guide ..."
document.attempts  #=> [direct: :ok]

# Answer a question with sources
{:ok, answer} = Perplexed.answer("When did the first Ferris wheel open?", max_sources: 5)
answer.answer      #=> "The first Ferris wheel opened in June 1893 [1][2]."
answer.sources     #=> [%Perplexed.Answer.Source{number: 1, url: ..., tier: :direct}, ...]
answer.usage       #=> %{model_calls: 3, searches: 3, total_cost: 0.011, ...}
```

Pass a Zoi `:schema` to `answer/2` for a validated object instead of text.
The default scrape ladder is `[:direct, :impersonated, :firecrawl]`; pass
`ladder:` (or set it in the settings) to use `:browser_run` or your own
`Perplexed.Scraper`. See the module docs for every option, the provider
prices and the telemetry events.

## License

MIT. See [LICENSE](https://github.com/agoodway/perplexed/blob/main/LICENSE).
