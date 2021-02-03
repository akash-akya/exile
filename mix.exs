defmodule Exile.MixProject do
  use Mix.Project

  def project do
    [
      app: :exile,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: "https://github.com/akash-akya/exile",
      homepage_url: "https://github.com/akash-akya/exile",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Exile, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    "NIF based solution to interact with external programs with back-pressure"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["MIT"],
      links: %{GitHub: "https://github.com/akash-akya/exile"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.6", runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev}
    ]
  end
end
