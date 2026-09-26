defmodule Opsonde.Targets.BMCOperation.Validations.Definition do
  use Ash.Resource.Validation

  alias Opsonde.Targets
  alias Opsonde.Targets.BMC.CurrentAccessMethod
  alias Opsonde.Targets.BMC.JSONPointer
  alias Opsonde.Targets.BMC.Redfish.ResourceURI

  @dynamic_object_keywords ~w(patternProperties unevaluatedProperties propertyNames allOf anyOf oneOf not if then else $ref)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    method_id = Ash.Changeset.get_attribute(changeset, :access_method_id)
    kind = Ash.Changeset.get_attribute(changeset, :request_kind)
    protocol_request = Ash.Changeset.get_attribute(changeset, :protocol_request)
    secret_bindings = Ash.Changeset.get_attribute(changeset, :secret_bindings)
    parameter_classes = Ash.Changeset.get_attribute(changeset, :parameter_classes)
    input_schema = Ash.Changeset.get_attribute(changeset, :input_schema)

    with {:ok, method} <- CurrentAccessMethod.get(method_id),
         :ok <- valid_request(method.method, kind, protocol_request),
         :ok <- valid_secret_bindings(method, secret_bindings),
         :ok <- valid_schema(changeset, :input_schema),
         true <- closed_input_schema?(input_schema),
         true <- secret_pointers_hidden?(input_schema, secret_bindings),
         true <- classified_parameters?(input_schema, secret_bindings, parameter_classes),
         :ok <- valid_schema(changeset, :output_schema),
         :ok <- optional_schema(changeset, :verification_schema) do
      :ok
    else
      _ ->
        {:error,
         field: :protocol_request,
         message: "BMC operation must match an active Access Method and a valid protocol request"}
    end
  end

  defp valid_request("redfish", kind, %{"method" => method, "uri" => uri} = request)
       when is_binary(method) and is_binary(uri) do
    allowed =
      if kind == :observation, do: ["GET", "HEAD"], else: ["POST", "PATCH", "PUT", "DELETE"]

    if method in allowed and Enum.sort(Map.keys(request)) == ["method", "uri"] and
         match?({:ok, _path}, ResourceURI.relative(uri)),
       do: :ok,
       else: :error
  end

  defp valid_request("ipmi", kind, %{"netfn" => netfn, "command" => command} = request)
       when kind in [:observation, :effect] and is_integer(netfn) and is_integer(command) do
    if Enum.sort(Map.keys(request)) == ["command", "netfn"] and netfn in 0..62 and
         rem(netfn, 2) == 0 and command in 0..255, do: :ok, else: :error
  end

  defp valid_request(_, _, _), do: :error

  defp valid_secret_bindings(_method, bindings) when bindings == %{}, do: :ok

  defp valid_secret_bindings(method, bindings)
       when is_map(bindings) and map_size(bindings) <= 20 do
    Enum.reduce_while(bindings, :ok, fn {pointer, reference}, :ok ->
      with {:ok, _path} <- JSONPointer.segments(pointer),
           %{"id" => id, "revision" => revision} <- reference,
           true <- map_size(reference) == 2 and is_integer(revision) and revision > 0,
           {:ok, uuid} <- Ecto.UUID.cast(id),
           {:ok, %{active: true, access_method_id: method_id, revision: ^revision}} <-
             Targets.get_bmc_secret(uuid, authorize?: false),
           true <- method_id == method.id do
        {:cont, :ok}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp valid_secret_bindings(_, _), do: :error

  defp closed_input_schema?(schema) do
    properties = schema["properties"]

    closed_object?(schema) and is_map(properties) and
      Map.has_key?(properties, "selectors") and
      Map.has_key?(properties, "parameters") and
      closed_object?(properties["selectors"]) and
      Map.get(properties["selectors"], "properties", %{}) == %{} and
      closed_object?(properties["parameters"])
  end

  defp closed_object?(%{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})

    schema["additionalProperties"] == false and is_map(properties) and
      Enum.all?(@dynamic_object_keywords, &(not Map.has_key?(schema, &1))) and
      Enum.all?(properties, fn {_name, child} -> closed_child?(child) end)
  end

  defp closed_object?(_schema), do: false

  defp closed_child?(%{"type" => "object"} = schema), do: closed_object?(schema)
  defp closed_child?(%{"type" => "array", "items" => items}), do: closed_child?(items)

  defp closed_child?(%{"type" => type})
       when type in ["string", "integer", "number", "boolean", "null"], do: true

  defp closed_child?(_schema), do: false

  defp classified_parameters?(schema, bindings, classes)
       when is_map(classes) and map_size(classes) <= 100 do
    parameters = get_in(schema, ["properties", "parameters"])
    public_paths = parameter_paths(parameters, "")
    expected = MapSet.new(public_paths ++ Map.keys(bindings))

    MapSet.new(Map.keys(classes)) == expected and
      Enum.all?(public_paths, &(classes[&1] == "public")) and
      Enum.all?(Map.keys(bindings), &(classes[&1] == "secret"))
  end

  defp classified_parameters?(_schema, _bindings, _classes), do: false

  defp parameter_paths(%{"type" => "object"} = schema, prefix) do
    schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {key, child} ->
      path = JSONPointer.append(prefix, key)

      case child do
        %{"type" => "object"} -> parameter_paths(child, path)
        _ -> [path]
      end
    end)
  end

  defp secret_pointers_hidden?(_schema, bindings) when bindings == %{}, do: true

  defp secret_pointers_hidden?(schema, bindings) do
    parameters = get_in(schema, ["properties", "parameters"])

    Enum.all?(Map.keys(bindings), fn pointer ->
      case JSONPointer.segments(pointer) do
        {:ok, path} -> hidden_path?(path, parameters)
        :error -> false
      end
    end)
  end

  defp hidden_path?([key], %{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})
    not Map.has_key?(properties, key) and key not in Map.get(schema, "required", [])
  end

  defp hidden_path?([key | rest], %{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})

    case Map.fetch(properties, key) do
      {:ok, child} -> hidden_path?(rest, child)
      :error -> true
    end
  end

  defp hidden_path?(_path, _schema), do: false

  defp valid_schema(changeset, attribute) do
    value = Ash.Changeset.get_attribute(changeset, attribute)

    with true <- is_map(value) and value["type"] == "object",
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= 32_768,
         {:ok, %JSV.Root{}} <- JSV.build(value, warnings: :silent) do
      :ok
    else
      _ -> :error
    end
  end

  defp optional_schema(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> :ok
      _value -> valid_schema(changeset, attribute)
    end
  end
end
