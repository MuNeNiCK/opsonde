defmodule Opsonde.MixProject do
  use Mix.Project

  def project do
    [
      app: :opsonde,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      default_release: :opsonde_server,
      releases: releases(),
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Opsonde.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp usage_rules do
    [
      skills: [
        location: ".agents/skills",
        build: [
          "ash-framework": [
            description:
              "Load before changing Ash.Domain, Ash.Resource, Ash actions, policies, changes, validations, AshPostgres persistence, AshAuthentication, or AshPhoenix integration, and before running Ash generators.",
            usage_rules: [:ash, ~r/^ash_/]
          ]
        ]
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:oban, "~> 2.0"},
      {:cloak, "~> 1.0"},
      {:ash_cloak, "~> 0.4"},
      {:argon2_elixir, "~> 4.0"},
      {:simple_sat, "~> 0.1"},
      {:ash_authentication, "~> 4.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:nimble_csv, "~> 1.3"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:burrito, "== 1.5.0"}
    ]
  end

  defp releases do
    [
      opsonde_server: [],
      opsonde: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ash.setup",
        "run priv/repo/seeds.exs",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["cmd npm --prefix assets ci"],
      "assets.build": ["cmd npm --prefix assets run build"],
      test: ["ash.setup --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd npm --prefix assets run check",
        "assets.build",
        "test"
      ]
    ]
  end
end
