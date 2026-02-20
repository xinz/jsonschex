defmodule Bench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bench,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jsv, github: "lud/jsv"},
      {:json_xema, github: "hrzndhrn/json_xema"},
      {:jsonschex, path: "../", override: true},
      {:benchee, "~> 1.5", only: :dev, runtime: false}
    ]
  end
end
