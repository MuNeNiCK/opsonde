defmodule Opsonde.Targets.Artifact.Actions.Lifecycle do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.Targets
  alias Opsonde.Targets.{Artifact, ArtifactChunk, Target}
  alias Opsonde.Providers.Target.FileReference

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :limits -> {:ok, limits()}
      :begin -> begin_upload(input.arguments, context.actor)
      :append -> locked(input.arguments.id, context.actor, &append(&1, input.arguments))
      :complete -> locked(input.arguments.id, context.actor, &complete/1)
      :revoke -> locked(input.arguments.id, context.actor, &dispose(&1, :revoked), usable?: false)
      :expire -> locked(input.arguments.id, nil, &expire/1, usable?: false, authorize?: false)
      :chunk -> read_chunk(input.arguments, context.actor)
      :reference -> reference(input.arguments, context.actor)
      :bound_chunk -> bound_chunk(input.arguments, context.actor)
    end
  end

  defp begin_upload(arguments, actor) do
    Ash.transact([Target, Artifact], fn -> create_or_resume(arguments, actor) end)
  end

  defp create_or_resume(arguments, actor) do
    with true <-
           arguments.size_bytes <= limits().max_size_bytes ||
             invalid(:size_bytes, "Artifact exceeds the configured transfer limit"),
         {:ok, %{active: true}} <-
           Target
           |> Ash.Query.for_read(:read, %{}, actor: actor)
           |> Ash.Query.filter(id == ^arguments.target_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(not_found_error?: true),
         {:ok, existing} <-
           Targets.artifact_by_upload(arguments.target_id, actor.id, arguments.upload_key,
             authorize?: false,
             not_found_error?: false
           ) do
      if existing do
        if Enum.all?(
             [:name, :media_type, :size_bytes, :expected_sha256],
             &(Map.get(existing, &1) == Map.get(arguments, &1))
           ),
           do: existing,
           else: invalid(:upload_key, "This upload key already identifies different content")
      else
        attributes =
          arguments
          |> Map.take([
            :target_id,
            :name,
            :media_type,
            :size_bytes,
            :expected_sha256,
            :upload_key
          ])
          |> Map.merge(%{
            uploaded_by_id: actor.id,
            expires_at: DateTime.add(DateTime.utc_now(), limits().lifetime_seconds, :second)
          })

        with {:ok, artifact} <- Targets.create_artifact_record(attributes, authorize?: false),
             {:ok, _job} <- schedule_expiry(artifact) do
          artifact
        end
      end
    else
      {:error, _} = error -> error
      _ -> invalid(:target_id, "Artifact Target is unavailable")
    end
  end

  defp schedule_expiry(artifact) do
    %{id: artifact.id}
    |> Artifact.ExpiryWorker.new(scheduled_at: artifact.expires_at)
    |> Oban.insert()
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       Ash.Error.Unknown.UnknownError.exception(error: "Artifact cleanup could not be saved")}
  end

  defp locked(id, actor, operation, opts \\ []) do
    Ash.transact([Artifact, ArtifactChunk], fn ->
      with {:ok, artifact} <-
             Artifact
             |> Ash.Query.for_read(:read, %{},
               actor: actor,
               authorize?: Keyword.get(opts, :authorize?, true)
             )
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read_one(not_found_error?: true),
           :ok <- if(Keyword.get(opts, :usable?, true), do: unexpired(artifact), else: :ok) do
        operation.(artifact)
      end
    end)
  end

  defp append(artifact, %{offset: offset, bytes: bytes}) do
    size = byte_size(bytes)

    cond do
      artifact.status in [:revoked, :expired] ->
        invalid(:id, "Artifact is unavailable")

      size == 0 or size > limits().chunk_bytes ->
        invalid(:bytes, "Chunk exceeds the configured transfer limit")

      offset < artifact.received_bytes ->
        duplicate_chunk(artifact, offset, bytes)

      artifact.status != :uploading ->
        invalid(:id, "Artifact is already complete")

      offset != artifact.received_bytes ->
        invalid(:offset, "Chunk must continue the current upload offset")

      offset + size > artifact.size_bytes ->
        invalid(:bytes, "Chunk exceeds declared artifact length")

      true ->
        with {:ok, _chunk} <-
               Targets.create_artifact_chunk_record(
                 %{
                   artifact_id: artifact.id,
                   offset: offset,
                   size_bytes: size,
                   sha256: digest(bytes),
                   bytes: bytes
                 },
                 authorize?: false
               ),
             {:ok, updated} <-
               Targets.record_artifact_state(artifact, %{received_bytes: offset + size},
                 authorize?: false
               ) do
          updated
        end
    end
  end

  defp duplicate_chunk(artifact, offset, bytes) do
    with {:ok, chunk} <- Targets.artifact_chunk_at_offset(artifact.id, offset, authorize?: false),
         true <- chunk.size_bytes == byte_size(bytes) and chunk.sha256 == digest(bytes) do
      artifact
    else
      _ -> invalid(:offset, "A different chunk already occupies this offset")
    end
  end

  defp complete(%{status: :ready} = artifact), do: artifact

  defp complete(%{status: status}) when status in [:revoked, :expired],
    do: invalid(:id, "Artifact is unavailable")

  defp complete(artifact) do
    with true <-
           artifact.received_bytes == artifact.size_bytes ||
             invalid(:id, "Artifact upload is incomplete"),
         {:ok, hash} <- hash_chunks(artifact, 0, :crypto.hash_init(:sha256)),
         true <-
           hash == artifact.expected_sha256 ||
             invalid(:expected_sha256, "Artifact integrity check failed"),
         {:ok, completed} <-
           Targets.record_artifact_state(artifact, %{status: :ready, sha256: hash},
             authorize?: false
           ) do
      completed
    end
  end

  defp hash_chunks(artifact, offset, hash) when offset == artifact.size_bytes,
    do: {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  defp hash_chunks(artifact, offset, hash) do
    with {:ok, chunk} <-
           Targets.artifact_chunk_at_offset(artifact.id, offset,
             authorize?: false,
             load: [:bytes]
           ),
         :ok <- chunk_integrity(chunk) do
      hash_chunks(artifact, offset + chunk.size_bytes, :crypto.hash_update(hash, chunk.bytes))
    end
  end

  defp read_chunk(arguments, actor) do
    with {:ok, artifact} <- Targets.get_artifact(arguments.id, actor: actor),
         :ok <- ready_for_target(artifact, arguments.target_id) do
      read_verified_chunk(artifact, arguments.offset)
    end
  end

  defp reference(arguments, actor) do
    with {:ok, artifact} <- Targets.get_artifact(arguments.id, actor: actor),
         :ok <- ready_for_target(artifact, arguments.target_id) do
      {:ok, FileReference.from_metadata(artifact)}
    end
  end

  defp bound_chunk(%{reference: reference, offset: offset}, actor) do
    if FileReference.valid?(reference) do
      locked(reference["id"], actor, fn artifact ->
        with :ok <- ready_for_target(artifact, reference["target_id"]),
             true <-
               FileReference.from_metadata(artifact) == reference ||
                 invalid(:reference, "File reference does not match the stored content"),
             {:ok, bytes} <- read_verified_chunk(artifact, offset) do
          bytes
        end
      end)
    else
      invalid(:reference, "File reference is invalid")
    end
  end

  defp ready_for_target(artifact, target_id) do
    with true <-
           artifact.target_id == target_id ||
             invalid(:target_id, "Artifact does not belong to this Target"),
         true <- artifact.status == :ready || invalid(:id, "Artifact is not ready"),
         :ok <- unexpired(artifact),
         do: :ok
  end

  defp read_verified_chunk(%{size_bytes: 0}, 0), do: {:ok, <<>>}

  defp read_verified_chunk(artifact, offset) do
    with {:ok, chunk} <-
           Targets.artifact_chunk_at_offset(artifact.id, offset,
             authorize?: false,
             load: [:bytes]
           ),
         :ok <- chunk_integrity(chunk) do
      {:ok, chunk.bytes}
    end
  end

  defp expire(%{status: status} = artifact) when status in [:expired, :revoked], do: artifact

  defp expire(artifact) do
    if DateTime.compare(artifact.expires_at, DateTime.utc_now()) == :gt,
      do: artifact,
      else: dispose(artifact, :expired)
  end

  defp dispose(%{status: status} = artifact, status), do: artifact
  defp dispose(%{status: :expired} = artifact, :revoked), do: artifact

  defp dispose(artifact, status) do
    result =
      ArtifactChunk
      |> Ash.Query.filter(artifact_id == ^artifact.id)
      |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true)

    case result do
      %Ash.BulkResult{status: :success} ->
        with {:ok, revoked} <-
               Targets.record_artifact_state(artifact, %{status: status}, authorize?: false),
             do: revoked

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp chunk_integrity(chunk) do
    if byte_size(chunk.bytes) == chunk.size_bytes and digest(chunk.bytes) == chunk.sha256,
      do: :ok,
      else: invalid(:id, "Stored artifact integrity check failed")
  end

  defp unexpired(artifact) do
    if DateTime.compare(artifact.expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: invalid(:id, "Artifact has expired")
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp limits do
    %{chunk_bytes: 262_144, max_size_bytes: 536_870_912, lifetime_seconds: 86_400}
    |> Map.merge(Application.get_env(:opsonde, :artifact_limits, %{}))
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
