defmodule OpsondeWeb.API.V1.BMCSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias OpsondeWeb.API.Schemas

  def components do
    %{
      "BMCOperation" => operation(),
      "BMCOperationResponse" => Schemas.data(ref("BMCOperation")),
      "BMCOperationPage" => Schemas.page(ref("BMCOperation")),
      "CreateBMCOperationRequest" => create_operation(),
      "UpdateBMCOperationRequest" => update_operation(),
      "DeactivateBMCOperationRequest" => revision_request(:bmc_operation),
      "BMCSecret" => secret(),
      "BMCSecretResponse" => Schemas.data(ref("BMCSecret")),
      "BMCSecretPage" => Schemas.page(ref("BMCSecret")),
      "CreateBMCSecretRequest" => create_secret(),
      "UpdateBMCSecretRequest" => update_secret(),
      "DeactivateBMCSecretRequest" => revision_request(:bmc_secret)
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp operation do
    record(
      %{
        name: string(1, 120),
        description: string(1, 500),
        request_kind: %Schema{type: :string, enum: ~w(observation effect)},
        protocol_request: map(),
        secret_bindings: map(),
        parameter_classes: map(),
        input_schema: map(),
        output_schema: map(),
        verification_schema: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      [
        :name,
        :description,
        :request_kind,
        :protocol_request,
        :secret_bindings,
        :parameter_classes,
        :input_schema,
        :output_schema,
        :verification_schema
      ]
    )
  end

  defp secret do
    record(%{name: string(1, 120)}, [:name])
  end

  defp create_operation do
    wrapped(
      :bmc_operation,
      %{
        name: string(1, 120),
        description: string(1, 500),
        request_kind: %Schema{type: :string, enum: ~w(observation effect)},
        protocol_request: map(),
        secret_bindings: map(),
        parameter_classes: map(),
        input_schema: map(),
        output_schema: map(),
        verification_schema: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      [:name, :description, :request_kind, :protocol_request, :input_schema, :output_schema]
    )
  end

  defp update_operation do
    update(:bmc_operation, %{
      name: string(1, 120),
      description: string(1, 500),
      request_kind: %Schema{type: :string, enum: ~w(observation effect)},
      protocol_request: map(),
      secret_bindings: map(),
      parameter_classes: map(),
      input_schema: map(),
      output_schema: map(),
      verification_schema: %Schema{type: :object, additionalProperties: true, nullable: true}
    })
  end

  defp create_secret do
    wrapped(:bmc_secret, %{name: string(1, 120), value: string(1, 4_096)}, [:name, :value])
  end

  defp update_secret do
    update(:bmc_secret, %{name: string(1, 120), value: string(1, 4_096)})
  end

  defp revision_request(name),
    do: wrapped(name, %{expected_revision: integer()}, [:expected_revision])

  defp update(name, fields) do
    wrapped(name, Map.put(fields, :expected_revision, integer()), [:expected_revision])
    |> put_in([Access.key(:properties), name, Access.key(:minProperties)], 2)
  end

  defp record(fields, required) do
    object(
      Map.merge(fields, %{
        id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        active: %Schema{type: :boolean},
        revision: integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      }),
      [:id, :access_method_id, :active, :revision, :inserted_at, :updated_at | required]
    )
  end

  defp wrapped(name, fields, required), do: object(%{name => object(fields, required)}, [name])

  defp object(fields, required),
    do: %Schema{
      type: :object,
      properties: fields,
      required: required,
      additionalProperties: false
    }

  defp string(min, max), do: %Schema{type: :string, minLength: min, maxLength: max}
  defp integer, do: %Schema{type: :integer, minimum: 1}
  defp map, do: %Schema{type: :object, additionalProperties: true}
end
