defmodule Opsonde.Targets.BMCOperation.Validations.Definition do
  use Ash.Resource.Validation

  alias Opsonde.{Providers, Targets}

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    method_id = Ash.Changeset.get_attribute(changeset, :access_method_id)
    kind = Ash.Changeset.get_attribute(changeset, :request_kind)
    protocol_request = Ash.Changeset.get_attribute(changeset, :protocol_request)

    with {:ok, %{active: true} = method} <-
           Targets.get_access_method(method_id, authorize?: false),
         {:ok, %{active: true, kind: "physical_host"}} <-
           Targets.get_target(method.target_id, authorize?: false),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             method.provider_id,
             method.provider_revision,
             :target,
             authorize?: false
           ),
         true <- method.method in ["redfish", "ipmi"],
         true <- protocol_matches?(provider.adapter_type, method.method),
         :ok <- valid_request(method.method, kind, protocol_request),
         :ok <- valid_schema(changeset, :input_schema),
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

  defp protocol_matches?("bmc-redfish", "redfish"), do: true
  defp protocol_matches?("bmc-ipmi", "ipmi"), do: true
  defp protocol_matches?(_, _), do: false

  defp valid_request("redfish", kind, %{"method" => method, "uri" => uri} = request)
       when is_binary(method) and is_binary(uri) do
    allowed =
      if kind == :observation, do: ["GET", "HEAD"], else: ["POST", "PATCH", "PUT", "DELETE"]

    if method in allowed and Enum.sort(Map.keys(request)) == ["method", "uri"] and
         byte_size(uri) in 11..2_048 and valid_relative_uri?(uri),
       do: :ok,
       else: :error
  end

  defp valid_request("ipmi", kind, %{"netfn" => netfn, "command" => command} = request)
       when kind in [:observation, :effect] and is_integer(netfn) and is_integer(command) do
    if Enum.sort(Map.keys(request)) == ["command", "netfn"] and netfn in 0..62 and
         rem(netfn, 2) == 0 and command in 0..255, do: :ok, else: :error
  end

  defp valid_request(_, _, _), do: :error

  defp valid_relative_uri?(uri) do
    parsed = URI.parse(uri)
    decoded = if is_binary(parsed.path), do: URI.decode(parsed.path), else: ""
    segments = String.split(decoded, "/", trim: true)

    is_nil(parsed.scheme) and is_nil(parsed.host) and is_nil(parsed.userinfo) and
      is_nil(parsed.fragment) and is_binary(parsed.path) and
      (decoded == "/redfish/v1" or String.starts_with?(decoded, "/redfish/v1/")) and
      not String.contains?(decoded, ["\\", "//"]) and
      Enum.all?(segments, &(&1 not in [".", ".."]))
  end

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
