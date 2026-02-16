defmodule JSONSchex.MixProject do
  use Mix.Project

  def project do
    [
      app: :jsonschex,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs()
    ]
  end

  def elixirc_paths(:test), do: ["lib", "test/support"]
  def elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guide/loader.md",
        "guide/dialect_and_vocabulary.md",
        "guide/feature_matrix.md",
        "guide/content_and_format.md",
        "guide/test_suite.md"
      ],
      groups_for_extras: [
        Guides: [
          "guide/loader.md",
          "guide/dialect_and_vocabulary.md",
          "guide/feature_matrix.md",
          "guide/content_and_format.md",
          "guide/test_suite.md"
        ]
      ],
      groups_for_modules: [
        "Public API": [
          JSONSchex
        ],
        "Types": [
          JSONSchex.Types,
          JSONSchex.Types.Schema,
          JSONSchex.Types.Rule,
          JSONSchex.Types.Error
        ],
        "Compiler": [
          JSONSchex.Compiler,
          JSONSchex.Compiler.ECMARegex,
          JSONSchex.Compiler.Predicates,
          JSONSchex.Compiler.Predicates.MultipleOf
        ],
        "Validator": [
          JSONSchex.Validator,
          JSONSchex.Validator.Keywords,
          JSONSchex.Validator.Reference
        ],
        "Formats": [
          JSONSchex.Formats,
          JSONSchex.Formats.DateTime,
          JSONSchex.Formats.Email,
          JSONSchex.Formats.Hostname,
          JSONSchex.Formats.IP,
          JSONSchex.Formats.Regex,
          JSONSchex.Formats.Time,
          JSONSchex.Formats.URITemplate
        ],
        "Internal": [
          JSONSchex.Vocabulary,
          JSONSchex.ScopeScanner,
          JSONSchex.URIUtil
        ]
      ],
      nest_modules_by_prefix: [
        JSONSchex.Types,
        JSONSchex.Compiler,
        JSONSchex.Validator,
        JSONSchex.Formats
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_json_pointer, "~> 0.5"},
      {:jason, "~> 1.4", optional: true},
      {:decimal, "~> 2.0", optional: true},
      {:idna, "~> 6.0 or ~> 7.1", optional: true},
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
