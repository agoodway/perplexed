# Perplexed

[![Hex.pm](https://img.shields.io/hexpm/v/perplexed.svg)](https://hex.pm/packages/perplexed)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/perplexed)
[![License](https://img.shields.io/hexpm/l/perplexed.svg)](https://github.com/agoodway/perplexed/blob/main/LICENSE)

A small Perplexity-style web search, scrape and answer toolkit for Elixir.

Perplexed searches the web through a provider you choose, reads the pages it
finds, and turns them into a cited answer on any model
[ReqLLM](https://hex.pm/packages/req_llm) supports.

- **Swappable search** - SearXNG, Firecrawl, Cloudflare Web Search (Ceramic,
  Linkup, Exa) and DeepSeek built in, or any module implementing
  `Perplexed.Search`, alone or as an ordered fallback chain.
- **Page reading** - fetches pages as Markdown, PDFs included, with hosted
  scrapers (DeepSeek, Firecrawl, Cloudflare Browser Run) as cheapest-first
  fallbacks for pages the free tiers cannot read.
- **Cited answers** - plan, search, rank, read and summarize, returning the
  sources used and every result considered.
- **Cost and telemetry** - USD cost on every search, scrape and model call.

## Installation

```elixir
def deps do
  [
    {:perplexed, "~> 0.2.0"}
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
See the module docs for every option, the provider prices and the telemetry
events.

## Providers and fallback chains

Search and page fetching are both chains you order yourself, so free and
cheap backends go first and paid ones catch what they miss.

### Search

`:provider` takes one provider or a list. A list is tried in order until one
answers; an error, a timeout or an empty result moves on to the next.

```elixir
config :perplexed,
  provider: [:deepseek, :firecrawl],
  deepseek_api_key: System.get_env("DEEPSEEK_API_KEY"),
  firecrawl_api_key: System.get_env("FIRECRAWL_API_KEY")

# or per call
Perplexed.search("zoning setbacks", provider: [:searxng, :deepseek, :firecrawl],
  provider_timeout_ms: 10_000, deadline_ms: 25_000)
```

Each provider gets `provider_timeout_ms` (default 15s) inside one
`deadline_ms` (default 30s). `fallback_on: [:error]` keeps an empty answer
instead of falling back. The result's `provider` is the one that answered
and `attempts` lists every step with its outcome, time and cost.

| Provider          | Per 1,000 searches | Notes                                          |
| ----------------- | ------------------ | ---------------------------------------------- |
| `:searxng`        | free               | Your SearXNG instances, or `:auto` public ones |
| `:ceramic`        | $0.25              | Cloudflare Web Search                          |
| `:deepseek`       | $0.75              | Page text included; empty results not billed   |
| `:firecrawl`      | $1.98              | Two credits at the Standard plan's rate        |
| `:linkup`         | $5.00              | Cloudflare Web Search                          |
| `:cloudflare_exa` | $7.00              | Cloudflare Web Search                          |

List prices as of 2026-11-10, from developers.cloudflare.com/web-search,
api-docs.deepseek.com and firecrawl.dev/pricing.

### Page fetching

The scrape ladder tries each rung until one returns a page worth reading.
The default is cheapest first: plain HTTP, then a browser TLS fingerprint
(both free), then DeepSeek Fetch and Firecrawl, each only when its key is
set (in the settings or the call's `credentials:`). `:browser_run` is
opt-in, and a ladder you set yourself is used as written.

```elixir
# the default, with both keys set
[:direct, :impersonated, :deepseek, :firecrawl]

config :perplexed, ladder: [:direct, :impersonated, :firecrawl]
Perplexed.scrape(url, ladder: [:direct, :firecrawl])
```

A 200 is not success: `Perplexed.Verdict` sends a bot challenge, a page that
says it is behind a sign-in or subscription, a JavaScript shell or a
near-empty page on to the next rung. A rung that cannot help with an outcome
is skipped (impersonation does nothing for a JavaScript shell), and a
missing page ends the climb. When a search provider already returned the
page text (DeepSeek does), `answer/2` reads that instead of fetching the
page again.

PDFs are read by the free rungs when a `Perplexed.PdfConverter` is
configured. Without one, a PDF ends the climb, unless you let Firecrawl read
it (`firecrawl_pdf: true`, at one credit per PDF page).

| Rung            | Per 1,000 pages | Notes                                       |
| --------------- | --------------- | ------------------------------------------- |
| `:direct`       | free            | Plain HTTP                                  |
| `:impersonated` | free            | Browser TLS/HTTP2 fingerprint (cloaked_req) |
| `:deepseek`     | $0.75           | DeepSeek Fetch; no JavaScript rendering     |
| `:firecrawl`    | $0.99           | Renders JavaScript; Standard plan rate      |
| `:browser_run`  | browser time    | Cloudflare; 10 h/month, then $0.09 an hour  |

List prices as of 2026-11-10. Firecrawl bills in credits, and what a credit
costs depends on your plan, so set it for accurate cost reports, for
example `config :perplexed, firecrawl_credit_usd: 0.0038` on Hobby. The
default is the Standard plan's $0.00099 ($99 for 100,000 credits).

Each step of a search chain emits `[:perplexed, :search, :attempt]`, and
each scrape rung tried emits `[:perplexed, :scrape, :attempt]`, with its
outcome, time, cost and whether it was billed, for tracking spend and
success per backend. A single search provider (not a list) emits only the
`[:perplexed, :search, :start | :stop]` span.

### Where data goes

Search providers see your queries, and `answer/2` also sends each the
user's question (`question:`; DeepSeek uses it as `ori_question`). With a
DeepSeek key set, the default ladder sends DeepSeek the URLs the free rungs
could not read. Searches through DeepSeek are processed by DeepSeek. Every
URL, including SearXNG instances, passes `Perplexed.UrlGuard` before a
request, so nothing reaches a private network; set `url_validator` to allow
a self-hosted instance on one.

### Adding a provider

A search provider is one module implementing `Perplexed.Search`; a page
fetcher implements `Perplexed.Scraper`. Pass either as `Module` or
`{Module, opts}` wherever a built-in name goes.

```elixir
defmodule MyApp.Search.Acme do
  @behaviour Perplexed.Search

  @impl true
  def search(query, opts) do
    # call the API, then normalize
    {:ok, [%Perplexed.Search.Hit{url: url, title: title, description: snippet,
                                 provider: :acme, metadata: %{score: score}}]}
  end

  @impl true
  def price(_opts), do: 0.001          # USD per request, for cost accounting

  @impl true
  def free_when_empty?, do: true       # optional
end

defmodule MyApp.Scraper.Acme do
  @behaviour Perplexed.Scraper

  @impl true
  def scrape(url, _opts), do: {:ok, %Perplexed.Document{markdown: markdown}, nil}

  @impl true
  def cost(_document, _opts), do: 0.0005

  @impl true
  def configured?(_opts), do: System.get_env("ACME_KEY") != nil   # optional
end
```

Return errors as `{:error, {reason, details}}` from a search provider and
`{:error, outcome_atom}` from a scraper; both chains move past them. A
search hit's `content` (page text) and `metadata` (scores, authority, site
name) are optional: `answer/2` reads the first and shows the ranking step
what it recognizes in the second.

## License

MIT. See [LICENSE](https://github.com/agoodway/perplexed/blob/main/LICENSE).
