[
  import_deps: [
    :ash_state_machine,
    :oban,
    :open_api_spex,
    :ash_authentication,
    :ash_phoenix,
    :ash_postgres,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  locals_without_parens: [
    state_attribute: 1,
    initial_states: 1,
    default_initial_state: 1,
    transition: 2
  ],
  subdirectories: ["priv/*/migrations"],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"],
  plugins: [Spark.Formatter]
]
