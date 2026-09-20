defmodule OpsondeWeb.API.OpenAPIError do
  @moduledoc false

  @behaviour Plug

  alias OpsondeWeb.API.Response

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    fields =
      errors
      |> Enum.flat_map(&field/1)
      |> Enum.uniq()
      |> Enum.sort()

    details = if fields == [], do: nil, else: %{fields: fields}

    Response.error(
      conn,
      :unprocessable_entity,
      "validation_failed",
      "Request validation failed",
      details
    )
  end

  defp field(%{name: name}) when is_atom(name), do: [Atom.to_string(name)]
  defp field(%{name: name}) when is_binary(name), do: [name]
  defp field(_error), do: []
end
