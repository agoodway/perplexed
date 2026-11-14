defmodule Perplexed.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/agoodway/perplexed"

  def project do
    [
      app: :perplexed,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),

      # Hex
      description: description(),
      package: package(),

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],

      # Docs
      name: "Perplexed",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [check: :test, precommit: :test, quality: :test]]
  end

  def application do
    [extra_applications: [:logger], mod: {Perplexed.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP
      {:req, "~> 0.7.5"},
      # Browser TLS/HTTP2 fingerprints for the impersonated scraper (Rust wreq NIF)
      {:cloaked_req, "~> 0.7.0"},
      {:html2markdown, "~> 0.3.2"},
      {:jason, "~> 1.4.5"},
      {:telemetry, "~> 1.4.2"},

      # Model calls and structured output for `Perplexed.answer/2`
      {:req_llm, "~> 1.28"},
      {:zoi, "~> 0.18.11"},

      # Test: Req's `plug:` option stands in for the network (dev: Tidewave's plug)
      {:plug, "~> 1.20", only: [:dev, :test]},

      # Dev/Test
      # Runtime MCP for coding agents: `mix tidewave` serves http://localhost:4000/tidewave/mcp
      {:tidewave, "~> 0.9.2", only: :dev},
      {:bandit, "~> 1.14", only: :dev},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      # Format, then compile strictly and test before committing
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "doctor",
        "test"
      ],
      # Run to check the quality of your code
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "sobelow --config",
        "ex_dna",
        "doctor",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "A small Perplexity-style web search and answer toolkit for Elixir: swappable search " <>
      "providers, page scraping, and cited answers on any ReqLLM model."
  end

  defp package do
    [
      maintainers: ["Chase Pursley"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Search: [~r/^Perplexed\.Search/],
        Scrape: [
          ~r/^Perplexed\.Scrape/,
          Perplexed.Document,
          Perplexed.Verdict,
          Perplexed.PdfConverter
        ],
        Answer: [~r/^Perplexed\.Answer/, Perplexed.Pipeline, Perplexed.Passages],
        Infrastructure: [Perplexed.Config, Perplexed.Telemetry, Perplexed.UrlGuard]
      ]
    ]
  end
end
