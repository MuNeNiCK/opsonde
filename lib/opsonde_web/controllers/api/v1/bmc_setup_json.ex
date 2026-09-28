defmodule OpsondeWeb.API.V1.BMCSetupJSON do
  @moduledoc false

  def operation(record) do
    %{
      id: record.id,
      access_method_id: record.access_method_id,
      name: record.name,
      description: record.description,
      request_kind: record.request_kind,
      protocol_request: record.protocol_request,
      secret_bindings: record.secret_bindings,
      parameter_classes: record.parameter_classes,
      input_schema: record.input_schema,
      output_schema: record.output_schema,
      verification_schema: record.verification_schema,
      active: record.active,
      revision: record.revision,
      inserted_at: record.inserted_at,
      updated_at: record.updated_at
    }
  end

  def secret(record) do
    %{
      id: record.id,
      access_method_id: record.access_method_id,
      name: record.name,
      active: record.active,
      revision: record.revision,
      inserted_at: record.inserted_at,
      updated_at: record.updated_at
    }
  end
end
