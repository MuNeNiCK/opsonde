defmodule Opsonde.Targets.Adapters.SSH.SFTP do
  @moduledoc false
  alias Opsonde.Providers.Target
  @read "request.ssh.observe"
  @write "request.ssh.effect"

  def capabilities do
    %Target.Capabilities{
      observations: [
        %Target.Operation{
          capability: @read,
          operation: "sftp.read_file",
          description:
            "Download exact remote file bytes over the registered SSH connection into an authenticated file; remote paths and permissions belong to the server",
          input_schema: schema(:read),
          output_schema: %{
            "type" => "object",
            "properties" => %{
              "file" => Target.FileReference.schema(),
              "completion_reason" => %{"const" => "eof"}
            },
            "required" => ~w(file completion_reason),
            "additionalProperties" => false
          },
          verification_schema: %{
            "type" => "object",
            "properties" =>
              Map.take(Target.FileReference.schema()["properties"], ~w(size_bytes sha256)),
            "additionalProperties" => false
          }
        }
      ],
      effects: [
        %Target.Operation{
          capability: @write,
          operation: "sftp.write_file",
          description:
            "Write admitted immutable file bytes to the exact remote path after authority review; existing content is overwritten, interrupted writes remain uncertain and are never automatically replayed",
          input_schema: schema(:write)
        }
      ]
    }
  end

  def operation(%{
        capability: @read,
        operation: "sftp.read_file",
        selectors: selectors,
        parameters: %{"path" => path, "response_file" => options} = parameters
      })
      when selectors == %{} and map_size(parameters) == 2 do
    if path?(path) and is_map(options) and Target.FileWriter.valid_options?(options),
      do: {:ok, %{kind: :read, path: path, output: options}},
      else: invalid()
  end

  def operation(%{
        capability: @write,
        operation: "sftp.write_file",
        selectors: selectors,
        parameters: %{"path" => path, "body_file" => label} = parameters,
        files: files
      })
      when selectors == %{} and map_size(parameters) == 2 do
    with true <- path?(path) and is_binary(label),
         {:ok, file} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(file),
         do: {:ok, %{kind: :write, path: path, label: label, file: file}},
         else: (_ -> invalid())
  end

  def operation(_request), do: invalid()

  # Compare only the caller's literal byte-integrity condition. This says
  # nothing about service recovery or the meaning of the downloaded content.
  def expected_status(_file, expected) when expected == %{}, do: :unknown

  def expected_status(file, expected) do
    if Enum.all?(expected, fn {key, value} ->
         key in ~w(size_bytes sha256) and Map.fetch(file, key) == {:ok, value}
       end), do: :verified, else: :not_verified
  end

  defp invalid, do: {:error, :failed, "SFTP request is invalid"}

  defp path?(path),
    do:
      is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
        not String.contains?(path, <<0>>)

  defp schema(kind) do
    properties = %{"path" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096}}

    properties =
      if kind == :read,
        do: Map.put(properties, "response_file", Target.FileWriter.options_schema()),
        else:
          Map.put(properties, "body_file", %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 120
          })

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => Map.keys(properties),
          "additionalProperties" => false
        }
      },
      "required" => ~w(selectors parameters),
      "additionalProperties" => false
    }
  end
end
