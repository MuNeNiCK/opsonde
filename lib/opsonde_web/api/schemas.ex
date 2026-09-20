defmodule OpsondeWeb.API.Schemas do
  @moduledoc false

  alias OpenApiSpex.Schema

  @error_descriptions %{
    bad_request: "Request body is invalid",
    unauthorized: "Authentication is required",
    forbidden: "The operation is not permitted",
    not_found: "Resource was not found",
    conflict: "Resource state conflicts with the request",
    unprocessable_entity: "Request validation failed",
    internal_server_error: "Request could not be completed"
  }

  def components do
    %{
      "Error" => error(),
      "ErrorResponse" => error_response(),
      "Page" => page()
    }
  end

  def uuid, do: %Schema{type: :string, format: :uuid}
  def timestamp, do: %Schema{type: :string, format: :"date-time"}

  def data(value) do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{data: value},
      required: [:data]
    }
  end

  def page(value) do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{
        data: %Schema{type: :array, items: value},
        page: reference("Page")
      },
      required: [:data, :page]
    }
  end

  def errors(statuses) do
    Enum.map(statuses, fn status ->
      {status,
       {Map.fetch!(@error_descriptions, status), "application/json", reference("ErrorResponse")}}
    end)
  end

  def reference(name), do: %OpenApiSpex.Reference{"$ref": "#/components/schemas/#{name}"}

  defp error do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{
        code: %Schema{type: :string},
        message: %Schema{type: :string},
        request_id: %Schema{type: :string, nullable: true},
        details: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      required: [:code, :message, :request_id]
    }
  end

  defp error_response do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{error: reference("Error")},
      required: [:error]
    }
  end

  defp page do
    %Schema{
      type: :object,
      additionalProperties: false,
      properties: %{next: %Schema{type: :string, nullable: true}},
      required: [:next]
    }
  end
end
