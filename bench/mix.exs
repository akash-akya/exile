defmodule ExileBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :exile_bench,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp aliases() do
    [
      "bench.io": ["run io.exs"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:benchee, "~> 1.0"},
      {:benchee_html, "~> 1.0"},
      {:exile, "~> 0.1", path: "../", override: true},
      {:ex_cmd, "~> 0.4.1"}
    ]
  end
end
