import Config
config :opsonde, Oban, testing: :manual
config :opsonde, token_signing_secret: "u1BW1Gxt1a++kTeasKEiwmx0VR8UEq+S"

config :opsonde,
  provider_adapters: [
    Opsonde.AI.ReqLLM,
    Opsonde.Inventories.NetBox.API,
    Opsonde.Notifications.HTTP.Webhook,
    Opsonde.Signals.Alertmanager.Webhook,
    Opsonde.Signals.Zabbix.Webhook,
    Opsonde.Targets.Generic.SSH,
    Opsonde.Targets.IOSXE.NETCONF,
    Opsonde.Targets.IOSXE.RESTCONF,
    Opsonde.Targets.IOSXE.SSH,
    Opsonde.Targets.Kubernetes.API,
    Opsonde.Targets.Linux.SSH,
    Opsonde.ProviderAdapterFixture,
    Opsonde.SignalAdapterFixture,
    Opsonde.InventoryAdapterFixture,
    Opsonde.NotificationAdapterFixture,
    Opsonde.AIAdapterFixture
  ]

config :opsonde, Opsonde.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: :binary.copy(<<2>>, 32), iv_length: 12}
  ]

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :opsonde, Opsonde.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "opsonde_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :opsonde, OpsondeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PEzzxwuJMDeoaHf/ExTM7wFbTJKP/Zt2Pq2WzyoLYsBx5F57jPh0DqceHKyojAKn",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
