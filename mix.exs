defmodule Exile.MixProject do
  use Mix.Project

  @version "0.12.0"
  @scm_url "https://github.com/akash-akya/exile"

  def project do
    [
      app: :exile,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      aliases: aliases(),

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: @scm_url,
      homepage_url: @scm_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", "LICENSE.md"]
      ]
    ]
  end

  def application do
    [
      mod: {Exile, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp description do
    "NIF based solution to interact with external programs with back-pressure"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["Apache-2.0"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* Makefile c_src/*.{h,c}),
      links: %{GitHub: @scm_url}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.6", runtime: false},

      # development & test
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:excoveralls, "~> 0.15", only: :test},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [docs: ["docs", &copy_images/1]]
  end

  defp copy_images(_) do
    File.cp_r("./images", "./doc/images/", fn source, destination ->
      IO.gets("Overwriting #{destination} by #{source}. Type y to confirm. ") == "y\n"
    end)
  end
end
