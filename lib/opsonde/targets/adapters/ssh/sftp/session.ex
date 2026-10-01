defmodule Opsonde.Targets.Adapters.SSH.SFTP.Session do
  @moduledoc false
  alias Opsonde.Providers.Target
  @capability "request.ssh.observe"
  @effect "request.ssh.effect"
  @flags %{
    "read" => :read,
    "write" => :write,
    "append" => :append,
    "creat" => :creat,
    "trunc" => :trunc,
    "excl" => :excl
  }
  @maximum_offset 18_446_744_073_709_551_615
  @maximum_read 536_870_912

  def observation do
    %Target.Operation{
      capability: @capability,
      operation: "sftp.session",
      description:
        "Run an exact finite native SFTP file session on one pinned connection; handles live only in this request and all must be explicitly closed",
      input_schema: schema(:read),
      output_schema: %{"type" => "object"},
      verification_schema: %{
        "type" => "object",
        "maxProperties" => 0,
        "additionalProperties" => false
      }
    }
  end

  def effect do
    %Target.Operation{
      capability: @effect,
      operation: "sftp.session",
      description:
        "Run exact native SFTP file steps and caller-selected open flags after independent authority review; interruption never replays the session",
      input_schema: schema(:write)
    }
  end

  def compile(%{
        capability: capability,
        selectors: selectors,
        parameters: %{"steps" => steps} = parameters,
        files: files
      })
      when capability in [@capability, @effect] and selectors == %{} and map_size(parameters) == 1 and
             is_list(steps) and
             length(steps) in 1..64 do
    with {:ok, {handles, compiled, mutation?}} <-
           Enum.reduce_while(steps, {:ok, {%{}, [], false}}, fn step,
                                                                {:ok,
                                                                 {handles, compiled, mutation?}} ->
             case admit_step(step, handles, files) do
               {:ok, next, admitted, mutating?} ->
                 {:cont, {:ok, {next, [admitted | compiled], mutation? or mutating?}}}

               error ->
                 {:halt, error}
             end
           end),
         true <- map_size(handles) == 0,
         true <- evidence_budget?(steps),
         true <- if(mutation?, do: capability == @effect, else: capability == @capability),
         do:
           {:ok,
            %{
              kind: if(mutation?, do: :session_write, else: :session_read),
              steps: Enum.reverse(compiled)
            }},
         else: (_ -> invalid())
  end

  def compile(_request), do: invalid()

  defp admit_step(
         %{"op" => "read", "handle" => _handle, "length" => _length, "response_file" => _output} =
           step,
         handles,
         files
       )
       when map_size(step) == 4 do
    case admit_step(Map.merge(step, %{"op" => "pread", "offset" => 0}), handles, files) do
      {:ok, next, _compiled, false} -> {:ok, next, step, false}
      error -> error
    end
  end

  defp admit_step(
         %{"op" => "write", "handle" => _handle, "body_file" => _label} = step,
         handles,
         files
       )
       when map_size(step) == 3 do
    case admit_step(Map.merge(step, %{"op" => "pwrite", "offset" => 0}), handles, files) do
      {:ok, next, compiled, true} ->
        {:ok, next, Map.delete(Map.put(compiled, "op", "write"), "offset"), true}

      error ->
        error
    end
  end

  defp admit_step(
         %{"op" => "position", "handle" => handle, "origin" => origin, "offset" => offset} = step,
         handles,
         _files
       )
       when map_size(step) == 4 and origin in ~w(bof cur eof) and is_integer(offset) and
              offset >= -@maximum_offset and offset <= @maximum_offset do
    if Map.has_key?(handles, handle), do: {:ok, handles, step, false}, else: invalid()
  end

  defp admit_step(%{"op" => "fstat", "handle" => handle} = step, handles, _files)
       when map_size(step) == 2 do
    if Map.has_key?(handles, handle), do: {:ok, handles, step, false}, else: invalid()
  end

  defp admit_step(
         %{"op" => "open", "handle" => handle, "path" => path, "flags" => flags} = step,
         handles,
         _files
       )
       when map_size(step) == 4 and is_list(flags) and length(flags) in 1..6 do
    if label?(handle) and path?(path) and not Map.has_key?(handles, handle) and
         Enum.uniq(flags) == flags and Enum.all?(flags, &Map.has_key?(@flags, &1)) do
      modes = Enum.map(flags, &Map.fetch!(@flags, &1))
      {:ok, Map.put(handles, handle, modes), Map.put(step, :flags, modes), modes != [:read]}
    else
      invalid()
    end
  end

  defp admit_step(
         %{
           "op" => "pread",
           "handle" => handle,
           "offset" => offset,
           "length" => length,
           "response_file" => output
         } = step,
         handles,
         _files
       )
       when map_size(step) == 5 and is_integer(offset) and offset >= 0 and
              is_integer(length) and length in 0..@maximum_read do
    if Map.has_key?(handles, handle) and offset + length <= @maximum_offset and
         is_map(output) and Target.FileWriter.valid_options?(output),
       do: {:ok, handles, step, false},
       else: invalid()
  end

  defp admit_step(
         %{"op" => "pwrite", "handle" => handle, "offset" => offset, "body_file" => label} = step,
         handles,
         files
       )
       when map_size(step) == 4 and is_integer(offset) and offset >= 0 do
    with true <- Map.has_key?(handles, handle),
         {:ok, file} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(file),
         true <- offset + file["size_bytes"] <= @maximum_offset,
         do: {:ok, handles, Map.merge(step, %{file: file, label: label}), true},
         else: (_ -> invalid())
  end

  defp admit_step(%{"op" => "close", "handle" => handle} = step, handles, _files)
       when map_size(step) == 2 do
    if Map.has_key?(handles, handle),
      do: {:ok, Map.delete(handles, handle), step, false},
      else: invalid()
  end

  defp admit_step(_step, _handles, _files), do: invalid()
  defp invalid, do: {:error, :failed, "SFTP session request is invalid"}
  defp label?(value), do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..120

  defp path?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..4096 and
        not String.contains?(value, <<0>>)

  # Reserve space for native attributes, file identities and interruption details
  # before dispatch; large file bytes belong in the existing file ports.
  defp evidence_budget?(steps) do
    Enum.reduce(steps, 6_000, fn
      %{"op" => op, "response_file" => output}, size when op in ["read", "pread"] ->
        size + 512 + byte_size(output["name"]) + byte_size(output["media_type"])

      %{"op" => "fstat"}, size ->
        size + 512

      _, size ->
        size + 256
    end) <= 60_000
  end

  defp schema(mode) do
    handle = %{"type" => "string", "minLength" => 1, "maxLength" => 120}

    open =
      step_schema(%{
        "op" => %{"const" => "open"},
        "handle" => handle,
        "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
        "flags" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 6,
          "uniqueItems" => true,
          "items" => %{
            "type" => "string",
            "enum" => if(mode == :read, do: ["read"], else: Map.keys(@flags))
          }
        }
      })

    read =
      step_schema(%{
        "op" => %{"const" => "pread"},
        "handle" => handle,
        "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => @maximum_offset},
        "length" => %{"type" => "integer", "minimum" => 0, "maximum" => @maximum_read},
        "response_file" => Target.FileWriter.options_schema()
      })

    close = step_schema(%{"op" => %{"const" => "close"}, "handle" => handle})

    write =
      step_schema(%{
        "op" => %{"const" => "pwrite"},
        "handle" => handle,
        "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => @maximum_offset},
        "body_file" => %{"type" => "string", "minLength" => 1, "maxLength" => 120}
      })

    sequential_read =
      step_schema(Map.delete(Map.put(read["properties"], "op", %{"const" => "read"}), "offset"))

    sequential_write =
      step_schema(Map.delete(Map.put(write["properties"], "op", %{"const" => "write"}), "offset"))

    fstat = step_schema(%{"op" => %{"const" => "fstat"}, "handle" => handle})

    position =
      step_schema(%{
        "op" => %{"const" => "position"},
        "handle" => handle,
        "origin" => %{"enum" => ~w(bof cur eof)},
        "offset" => %{
          "type" => "integer",
          "minimum" => -@maximum_offset,
          "maximum" => @maximum_offset
        }
      })

    choices =
      [open, read, sequential_read, position, fstat, close] ++
        if(mode == :write, do: [write, sequential_write], else: [])

    parameters =
      step_schema(%{
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 64,
          "items" => %{"oneOf" => choices}
        }
      })

    parameters =
      if mode == :write,
        do: put_in(parameters["properties"]["files"], Target.FileReference.set_schema()),
        else: parameters

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => parameters
      },
      "required" => ~w(selectors parameters),
      "additionalProperties" => false
    }
  end

  defp step_schema(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
end
