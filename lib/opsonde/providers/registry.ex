defmodule Opsonde.Providers.Registry do
  @moduledoc false

  alias Opsonde.Providers.Adapter

  @roles [:ai, :signal, :target, :inventory, :notification]
  @check_failures [:invalid_configuration, :authentication, :unreachable, :capability]

  def fetch(type) when is_binary(type) do
    case Enum.filter(adapters(), &(valid?(&1) and &1.type() == type)) do
      [adapter] -> {:ok, adapter}
      [] -> {:error, :unknown_adapter}
      _duplicates -> {:error, :duplicate_adapter}
    end
  end

  def fetch(_type), do: {:error, :unknown_adapter}

  def fetch(type, behaviour) when is_atom(behaviour) do
    with {:ok, adapter} <- fetch(type),
         true <- implements?(adapter, behaviour) do
      {:ok, adapter}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :unsupported_role}
    end
  end

  def role(adapter), do: adapter.role()

  def build(adapter, configuration, credentials)
      when is_atom(adapter) and is_map(configuration) and is_map(credentials) do
    case adapter.build(configuration, credentials) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_adapter_response}
    end
  rescue
    _error -> {:error, :invalid_adapter_configuration}
  catch
    _kind, _reason -> {:error, :invalid_adapter_configuration}
  end

  def build(_adapter, _configuration, _credentials),
    do: {:error, :invalid_adapter_configuration}

  def check(adapter, state, input) when is_atom(adapter) and is_map(input) do
    case adapter.check(state, input) do
      :ok ->
        :ok

      {:error, category, message} when category in @check_failures and is_binary(message) ->
        {:error, category, message}

      _other ->
        {:error, :provider_failure, "Provider check failed"}
    end
  rescue
    _error -> {:error, :provider_failure, "Provider check failed"}
  catch
    _kind, _reason -> {:error, :provider_failure, "Provider check failed"}
  end

  defp adapters, do: Application.get_env(:opsonde, :provider_adapters, [])

  defp valid?(adapter) do
    Code.ensure_loaded?(adapter) and
      Adapter in behaviours(adapter) and
      function_exported?(adapter, :type, 0) and
      function_exported?(adapter, :role, 0) and
      function_exported?(adapter, :build, 2) and
      function_exported?(adapter, :check, 2) and
      adapter.role() in @roles
  end

  defp behaviours(adapter) do
    adapter.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp implements?(adapter, behaviour) do
    Code.ensure_loaded?(behaviour) and
      behaviour in behaviours(adapter) and
      Enum.all?(behaviour.behaviour_info(:callbacks), fn {callback, arity} ->
        function_exported?(adapter, callback, arity)
      end)
  end
end
