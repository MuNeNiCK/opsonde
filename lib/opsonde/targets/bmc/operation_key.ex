defmodule Opsonde.Targets.BMC.OperationKey do
  @moduledoc false

  @prefix "bmc.api:"

  def format(%{id: id, revision: revision}) when is_binary(id) and is_integer(revision),
    do: @prefix <> id <> ":" <> Integer.to_string(revision)

  def parse(@prefix <> suffix) do
    case String.split(suffix, ":") do
      [id, revision_text] ->
        with {:ok, uuid} <- Ecto.UUID.cast(id),
             {revision, ""} when revision > 0 <- Integer.parse(revision_text) do
          {:ok, uuid, revision}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse(_value), do: :error

  def capability(:observation), do: "observe.bmc_api"
  def capability(:effect), do: "effect.bmc_api"
end
