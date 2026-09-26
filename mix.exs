defmodule Opsonde.MixProject do
  use Mix.Project

  def project do
    [
      app: :opsonde,
      version: "0.1.1",
      elixir: "~> 1.18",
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
      extra_applications: [:logger, :runtime_tools, :ssh]
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
      {:ash_state_machine, "~> 0.2.13"},
      {:req_llm, "~> 1.24"},
      {:req, "~> 0.7"},
      {:rustler, "== 0.38.0"},
      {:saxy, "~> 1.6"},
      {:tzdata, "~> 1.1"},
      {:crontab, "~> 1.2"},
      {:k8s, "~> 2.8"},
      {:yaml_elixir, "~> 2.12"},
      {:jsv, "~> 0.23"},
      {:oban, "~> 2.0"},
      {:cloak, "~> 1.0"},
      {:ash_cloak, "~> 0.4"},
      {:argon2_elixir, "~> 4.0"},
      {:simple_sat, "~> 0.1"},
      {:attesto_client, "~> 2.5"},
      {:attesto, "~> 2.1"},
      {:open_api_spex, "~> 3.22"},
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
      "assets.setup": ["cmd --cd assets corepack pnpm install --frozen-lockfile"],
      "assets.build": ["cmd --cd assets corepack pnpm run build"],
      test: ["ash.setup --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "openapi.spec.json --spec OpsondeWeb.ApiSpec --pretty=true --vendor-extensions=false --start-app=false --check=true --filename openapi.json",
        "cmd --cd assets corepack pnpm run check:api",
        "cmd --cd assets corepack pnpm run check",
        "assets.build",
        "test"
      ]
    ]
  end
end
