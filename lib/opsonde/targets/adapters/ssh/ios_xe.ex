defmodule Opsonde.Targets.Adapters.SSH.IOSXE do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Profiles.IOSXE
  alias Opsonde.Transports.SSH, as: Transport

  @native_observation "native.cli.observe"
  @native_effect "native.cli.effect"

  @impl Opsonde.Providers.Adapter
  def type, do: "ios-xe-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile,
    do: IOSXE.access_method_profile("ssh_cli", @native_observation, @native_effect)

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials), do: Transport.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(%Transport.Config{} = state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IOS XE SSH check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    capabilities = IOSXE.capabilities()

    {:ok,
     %{
       capabilities
       | observations: capabilities.observations ++ [native_observation()],
         effects: capabilities.effects ++ [native_effect()]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(
        %Transport.Config{} = state,
        %{capability: @native_observation} = request,
        invocation
      ) do
    with {:ok, commands} <- native_commands(request, "cli.observe"),
         true <- Enum.all?(commands, &IOSXE.ssh_readonly_command?/1),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), cancelled?(invocation)) do
      IOSXE.observation(%{"output" => output}, [evidence(output)])
    else
      false ->
        {:error, :failed, "CLI request is not provably non-mutating; submit it as an effect"}

      {:error, category, message} ->
        IOSXE.read_error(category, message)
    end
  end

  def observe(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             operation,
             cancelled?(invocation)
           ) do
      IOSXE.observation(facts, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def preflight(_state, %{capability: @native_observation} = request) do
    with {:ok, commands} <- native_commands(request, "cli.observe"),
         true <- Enum.all?(commands, &IOSXE.ssh_readonly_command?/1) do
      :ok
    else
      false -> {:error, :failed, "CLI observation must use show commands"}
      {:error, _category, _message} = error -> error
    end
  end

  def preflight(_state, request) do
    case IOSXE.observation_request(request) do
      {:ok, _operation} -> :ok
      {:error, _category, _message} = error -> error
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%Transport.Config{} = state, %{capability: @native_effect} = request, invocation) do
    with {:ok, commands} <- native_commands(request, "cli.execute"),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), cancelled?(invocation)),
         :ok <- IOSXE.ssh_command_accepted?(output) do
      IOSXE.applied(%{"output" => output})
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  def effect(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(
        state,
        request.connection.endpoint,
        operation,
        cancelled?(invocation)
      )
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(
        %Transport.Config{} = state,
        %{capability: @native_observation} = request,
        invocation
      ) do
    with {:ok, commands} <- native_commands(request, "cli.observe"),
         true <- Enum.all?(commands, &IOSXE.ssh_readonly_command?/1),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), cancelled?(invocation)) do
      IOSXE.verification(%{"output" => output}, request.expected, [evidence(output)])
    else
      false -> {:error, :failed, "CLI verification must be non-mutating"}
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  def verify(%Transport.Config{} = state, request, invocation) do
    with {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             {:interface, name},
             cancelled?(invocation)
           ) do
      IOSXE.verification(facts, expected, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  defp observe_operation(state, endpoint, :system, cancelled?) do
    with {:ok, output} <-
           run_shell(state, endpoint, script(IOSXE.ssh_system_commands()), cancelled?),
         {:ok, facts} <- IOSXE.ssh_system_facts(output) do
      {:ok, facts, output}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, cancelled?) do
    with {:ok, output} <-
           run_shell(state, endpoint, script(IOSXE.ssh_interface_commands(name)), cancelled?),
         {:ok, facts} <- IOSXE.ssh_interface_facts(name, output) do
      {:ok, facts, output}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, cancelled?) do
    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["description"], expected, "description"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(IOSXE.ssh_description_commands(name, desired)),
             cancelled?
           ),
         :ok <- IOSXE.ssh_command_accepted?(output) do
      IOSXE.applied(%{
        "interface" => name,
        "description" => desired,
        "evidence" => evidence(output)
      })
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, cancelled?) do
    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["enabled"], expected, "enabled"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(IOSXE.ssh_admin_state_commands(name, desired)),
             cancelled?
           ),
         :ok <- IOSXE.ssh_command_accepted?(output) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired, "evidence" => evidence(output)})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp run_shell(state, endpoint, script, cancelled?) do
    case Transport.shell(state, endpoint, script, cancelled?) do
      {:ok, %Transport.ShellResult{output: output}} -> {:ok, normalize(output)}
      {:error, category, message} -> {:error, category, message}
    end
  end

  defp native_commands(request, operation) do
    expected_capability =
      if(operation == "cli.observe", do: @native_observation, else: @native_effect)

    case request do
      %{
        capability: ^expected_capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{"commands" => commands}
      }
      when selectors == %{} and is_list(commands) and length(commands) in 1..50 ->
        if Enum.all?(commands, &(is_binary(&1) and byte_size(&1) in 1..1_024)),
          do: {:ok, commands},
          else: {:error, :failed, "IOS XE CLI commands are invalid"}

      _request ->
        {:error, :failed, "IOS XE native CLI request is invalid"}
    end
  end

  defp native_observation do
    output = %{
      "type" => "object",
      "properties" => %{"output" => %{"type" => "string", "maxLength" => 65_536}},
      "required" => ["output"],
      "additionalProperties" => false
    }

    %Target.Operation{
      capability: @native_observation,
      operation: "cli.observe",
      description: "Run exact IOS XE show commands and return raw output",
      input_schema: native_schema(),
      output_schema: output,
      verification_schema: Map.put(output, "minProperties", 1),
      native?: true
    }
  end

  defp native_effect do
    %Target.Operation{
      capability: @native_effect,
      operation: "cli.execute",
      description: "Run exact IOS XE CLI commands after authority review",
      input_schema: native_schema(),
      native?: true
    }
  end

  defp native_schema do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "commands" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => 50,
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024}
            }
          },
          "required" => ["commands"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp script(commands),
    do:
      Enum.join(["terminal length 0", "terminal width 511" | commands] ++ ["exit"], "\n") <> "\n"

  defp normalize(output) do
    output
    |> String.replace("\r", "")
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
  end

  defp evidence(output), do: %{"transport" => "ssh-cli", "output" => output}
  defp matches(observed, expected, _field) when observed == expected, do: :ok
  defp matches(observed, _expected, field), do: {:stale, observed, field}
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
