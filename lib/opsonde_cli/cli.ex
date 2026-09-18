defmodule OpsondeCLI.CLI do
  @moduledoc false

  alias OpsondeCLI.{BrowserLogin, Client, Commands, Config}
  alias OpsondeCLI.Commands.Route

  @exit %{
    succeeded: 0,
    resolved: 0,
    accepted: 10,
    resolving: 10,
    approval_required: 11,
    needs_attention: 12,
    failed: 13,
    partial: 14,
    unknown: 15,
    cancel_requested: 16
  }
  @terminal ~w(succeeded resolved needs_attention failed partial unknown cancel_requested)a
  @switches [
    input: :string,
    limit: :integer,
    after: :string,
    interval: :integer,
    timeout: :integer,
    server: :string,
    email: :string,
    oidc: :boolean
  ]

  def run(args, runtime_options \\ [])

  def run(["--version"], _runtime_options) do
    IO.puts("opsonde #{version()}")
    0
  end

  def run([], _runtime_options), do: help()
  def run(["--help"], _runtime_options), do: help()

  def run(["config", "set-server", server], runtime_options) do
    config_path = config_path(runtime_options)

    with {:ok, client} <- Client.new(server, nil),
         {:ok, config} <- Config.load(config_path),
         :ok <- Config.save(server_config(config, client.server), config_path) do
      print(%{"outcome" => "succeeded", "server" => client.server})
      0
    else
      {:error, message} -> local_error(message)
    end
  end

  def run(["config", "show"], runtime_options) do
    case Config.load(config_path(runtime_options)) do
      {:ok, config} ->
        print(%{
          "outcome" => "succeeded",
          "server" => config["server"],
          "authenticated" => is_binary(config["token"])
        })

        0

      {:error, message} ->
        local_error(message)
    end
  end

  def run(["auth", "login" | args], runtime_options), do: login(args, runtime_options)

  def run(args, runtime_options) do
    case Commands.lookup(args) do
      {:ok, route, ids, option_args, mode} ->
        execute(route, ids, option_args, mode, runtime_options)

      :error ->
        usage_error("Unknown or incomplete command")
    end
  end

  defp login(args, runtime_options) do
    with {:ok, options} <- parse_options(args),
         {:ok, config} <- Config.load(config_path(runtime_options)),
         server when is_binary(server) <- options[:server] || config["server"] do
      if options[:oidc] do
        oidc_login(server, options, runtime_options)
      else
        password_login(server, options, runtime_options)
      end
    else
      nil -> usage_error("auth login requires --server or saved server")
      {:error, message} -> local_error(message)
    end
  end

  defp password_login(server, options, runtime_options) do
    with email when is_binary(email) <- options[:email],
         {:ok, password} <- read_password(runtime_options),
         {:ok, client} <- Client.new(server, nil, request_options(runtime_options)),
         {:ok, _status, %{"data" => %{"token" => token, "account" => account}}} <-
           Client.request(client, :post, "/sessions", %{
             "session" => %{"email" => email, "password" => password}
           }),
         :ok <-
           Config.save(
             %{"server" => client.server, "token" => token},
             config_path(runtime_options)
           ) do
      print(%{"outcome" => "succeeded", "account" => account})
      0
    else
      nil -> usage_error("password login requires --email")
      {:error, :http, status, body} -> http_error(status, body)
      {:error, :transport, message} -> transport_error(message)
      {:error, message} -> local_error(message)
      _other -> local_error("Login response did not contain a session")
    end
  end

  defp oidc_login(server, options, runtime_options) do
    timeout = max(options[:timeout] || 300, 1) * 1_000
    browser_login = Keyword.get(runtime_options, :browser_login, &BrowserLogin.run/4)

    with {:ok, client} <- Client.new(server, nil, request_options(runtime_options)),
         {:ok, token, account} <-
           browser_login.(
             client,
             timeout,
             Keyword.get(runtime_options, :open_browser, &BrowserLogin.open_browser/1),
             Keyword.get(runtime_options, :listen, &:gen_tcp.listen/2)
           ),
         :ok <-
           Config.save(
             %{"server" => client.server, "token" => token},
             config_path(runtime_options)
           ) do
      print(%{"outcome" => "succeeded", "account" => account})
      0
    else
      {:error, :http, status, body} -> http_error(status, body)
      {:error, :transport, message} -> transport_error(message)
      {:error, message} -> local_error(message)
      _other -> local_error("OIDC login did not produce a session")
    end
  end

  defp execute(route, ids, args, mode, runtime_options) do
    with {:ok, options} <- parse_options(args),
         {:ok, config} <- Config.load(config_path(runtime_options)),
         :ok <- require_token(route, config),
         {:ok, client} <-
           Client.new(config["server"], config["token"], request_options(runtime_options)),
         {:ok, body} <- request_body(route, options, runtime_options) do
      if mode == :wait do
        wait(client, route, ids, options)
      else
        request_once(client, route, ids, body, options, runtime_options)
      end
    else
      {:error, message} -> local_error(message)
    end
  end

  defp request_once(client, route, ids, body, options, runtime_options) do
    case Client.request(
           client,
           route.method,
           Commands.path(route, ids),
           body,
           query(route, options)
         ) do
      {:ok, _status, response} ->
        result = outcome(route.outcome, response)

        with :ok <- maybe_clear_logout(route, runtime_options) do
          print(with_outcome(response, result))
          Map.fetch!(@exit, result)
        else
          {:error, message} -> local_error(message)
        end

      {:error, :http, status, body} ->
        http_error(status, body)

      {:error, :transport, message} ->
        transport_error(message)
    end
  end

  defp wait(client, route, ids, options) do
    interval = max(options[:interval] || 1_000, 50)
    timeout = max(options[:timeout] || 300, 0)
    deadline = System.monotonic_time(:millisecond) + timeout * 1_000
    poll(client, route, ids, interval, deadline)
  end

  defp poll(client, route, ids, interval, deadline) do
    case Client.request(client, route.method, Commands.path(route, ids)) do
      {:ok, _status, response} ->
        result = outcome(route.outcome, response)

        cond do
          result in @terminal or terminal_accepted?(route, response) ->
            print(with_outcome(response, result))
            Map.fetch!(@exit, result)

          System.monotonic_time(:millisecond) >= deadline ->
            print(with_outcome(response, result))
            Map.fetch!(@exit, result)

          true ->
            Process.sleep(interval)
            poll(client, route, ids, interval, deadline)
        end

      {:error, :http, status, body} ->
        http_error(status, body)

      {:error, :transport, message} ->
        transport_error(message)
    end
  end

  defp outcome(:case, %{"data" => %{"case" => incident} = snapshot}),
    do: case_outcome(incident, snapshot)

  defp outcome(:case_record, %{"data" => incident}), do: case_outcome(incident, %{})

  defp outcome(:operation, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "applied" => :resolved
      })

  defp outcome(:verification, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "verified" => :resolved,
        "not_verified" => :failed
      })

  defp outcome(:delivery, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "accepted" => :accepted,
        "delivered" => :resolved
      })

  defp outcome(:proposal, %{"data" => %{"status" => "awaiting_human"}}),
    do: :approval_required

  defp outcome(_kind, _response), do: :succeeded

  defp case_outcome(%{"cancel_requested" => true}, _snapshot), do: :cancel_requested
  defp case_outcome(%{"status" => "resolved"}, _snapshot), do: :resolved
  defp case_outcome(%{"status" => "needs_attention"}, _snapshot), do: :needs_attention
  defp case_outcome(%{"status" => "cancelled"}, _snapshot), do: :cancel_requested

  defp case_outcome(%{"status" => "running"}, snapshot) do
    proposals = Map.get(snapshot, "proposals", [])
    runs = Map.get(snapshot, "resolution_runs", [])

    cond do
      Enum.any?(proposals, &(&1["status"] == "awaiting_human")) -> :approval_required
      runs == [] -> :accepted
      true -> :resolving
    end
  end

  defp case_outcome(_incident, _snapshot), do: :unknown

  defp status_outcome(status, aliases) do
    Map.get(aliases, status) ||
      case status do
        "failed" -> :failed
        "partial" -> :partial
        "unknown" -> :unknown
        _other -> :unknown
      end
  end

  defp request_body(%Route{root: nil}, _options, _runtime_options), do: {:ok, nil}

  defp request_body(%Route{root: root}, options, runtime_options) do
    with path when is_binary(path) <- options[:input],
         {:ok, encoded} <- read_input(path, runtime_options),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(encoded) do
      {:ok, %{root => decoded}}
    else
      nil ->
        {:error, "This command requires --input FILE or --input -"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "Input is not valid JSON"}

      {:error, reason} when is_atom(reason) ->
        {:error, "Cannot read input: #{:file.format_error(reason)}"}

      _other ->
        {:error, "Input must be a JSON object"}
    end
  end

  defp read_input("-", runtime_options),
    do: {:ok, IO.read(runtime_options[:input] || :stdio, :eof)}

  defp read_input(path, _runtime_options), do: File.read(path)

  defp read_password(runtime_options) do
    case IO.read(runtime_options[:input] || :stdio, :eof) do
      :eof ->
        {:error, "Password must be supplied on standard input"}

      {:error, reason} ->
        {:error, "Cannot read password: #{inspect(reason)}"}

      password ->
        case password |> String.trim_trailing("\n") |> String.trim_trailing("\r") do
          "" -> {:error, "Password must be supplied on standard input"}
          value -> {:ok, value}
        end
    end
  end

  defp parse_options(args) do
    case OptionParser.parse(args, strict: @switches) do
      {options, [], []} ->
        {:ok, options}

      {_options, remaining, invalid} ->
        {:error, "Invalid options: #{inspect(invalid ++ remaining)}"}
    end
  end

  defp query(%Route{page?: true}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
  end

  defp query(_route, _options), do: []
  defp maybe_query(query, _key, nil), do: query
  defp maybe_query(query, key, value), do: [{key, value} | query]

  defp require_token(%Route{auth?: false}, _config), do: :ok
  defp require_token(_route, %{"token" => token}) when is_binary(token), do: :ok
  defp require_token(_route, _config), do: {:error, "Not authenticated. Run opsonde auth login"}

  defp maybe_clear_logout(%Route{path: "/session", method: :delete}, runtime_options),
    do: Config.clear_token(config_path(runtime_options))

  defp maybe_clear_logout(_route, _runtime_options), do: :ok

  defp terminal_accepted?(%Route{outcome: :delivery}, %{
         "data" => %{"status" => "accepted"}
       }),
       do: true

  defp terminal_accepted?(_route, _response), do: false

  defp server_config(%{"server" => server} = config, server), do: config

  defp server_config(config, server) do
    config
    |> Map.put("server", server)
    |> Map.delete("token")
  end

  defp with_outcome(response, result) when is_map(response),
    do: Map.put(response, "outcome", Atom.to_string(result))

  defp print(value), do: IO.puts(Jason.encode!(value, pretty: true))

  defp http_error(status, body) do
    print_error(Map.merge(%{"outcome" => "failed", "http_status" => status}, map_body(body)))
    if status == 401, do: 3, else: 4
  end

  defp transport_error(message) do
    print_error(%{
      "outcome" => "unknown",
      "error" => %{"code" => "transport_error", "message" => message}
    })

    5
  end

  defp local_error(message) do
    print_error(%{
      "outcome" => "failed",
      "error" => %{"code" => "local_error", "message" => message}
    })

    4
  end

  defp usage_error(message) do
    IO.puts(:stderr, message <> ". Run opsonde --help for usage.")
    2
  end

  defp print_error(value), do: IO.puts(:stderr, Jason.encode!(value))
  defp map_body(body) when is_map(body), do: body
  defp map_body(body), do: %{"error" => %{"message" => inspect(body)}}

  defp help do
    IO.puts("""
    Usage:
      opsonde config set-server URL
      opsonde config show
      printf 'PASSWORD' | opsonde auth login --server URL --email EMAIL
      opsonde auth login --oidc [--server URL] [--timeout SEC]
      opsonde auth bootstrap --input FILE
      opsonde auth status | logout
      opsonde RESOURCE ACTION [ID] [--input FILE|-] [--limit N] [--after CURSOR]
      opsonde case|operation|verification|delivery wait ID [--interval MS] [--timeout SEC]

    Resources:
      account provider ai-role boundary target identity access-method relationship policy
      inventory authority case proposal operation verification signal audit audit-run report delivery

    Input JSON contains the resource fields directly; the CLI adds the API envelope.
    Output is fixed-English JSON. Exit codes: 0 succeeded/resolved, 2 usage, 3 authentication,
    4 rejected, 5 transport, 10 accepted/resolving, 11 approval required, 12 needs attention,
    13 failed, 14 partial, 15 unknown, 16 cancellation requested.
    """)

    0
  end

  defp config_path(runtime_options), do: runtime_options[:config_path] || Config.path()
  defp request_options(runtime_options), do: runtime_options[:request_options] || []

  defp version do
    :opsonde
    |> Application.spec(:vsn)
    |> to_string()
  end
end
