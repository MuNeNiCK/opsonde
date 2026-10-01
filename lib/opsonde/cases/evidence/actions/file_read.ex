defmodule Opsonde.Cases.Evidence.Actions.FileRead do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.{Accounts, Cases, Targets}
  alias Opsonde.Cases.{Case, CaseEvent, Evidence, ResolutionRun, Turn}
  alias Opsonde.Cases.Case.{AdmissionLock, ConditionContext}
  alias Opsonde.Cases.Evidence.Citation
  alias Opsonde.Providers.AI
  alias Opsonde.Providers.Target.FileReference
  alias Opsonde.Targets.{Artifact, ArtifactChunk}

  @impl true
  def run(input, opts, _context) do
    Ash.transact([Case, ResolutionRun, Turn, Evidence, CaseEvent, Artifact, ArtifactChunk], fn ->
      case opts[:operation] do
        :capture ->
          with :ok <- AdmissionLock.acquire(), do: capture(input.arguments.turn_id)

        :read ->
          read(input.arguments)
      end
    end)
  end

  defp capture(turn_id) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         true <-
           (turn.status == :completed and turn.result["outcome"] == "decision" and
              get_in(turn.result, ["intent", "type"]) == "file_read") ||
             {:error, "Turn has no file-read decision"},
         {:ok, {incident, run, actor}} <- current_context(turn.case_id, turn.resolution_run_id),
         {:ok, true} <- ConditionContext.current?(incident, turn.id),
         intent <- turn.result["intent"],
         :ok <- valid_range(intent["reference"], intent["offset"], intent["length"], incident),
         true <-
           AI.valid_resolver_reason?(intent["reason"]) || {:error, "File-read reason is invalid"},
         {:ok, source} <- Cases.get_evidence(intent["source_evidence_id"], authorize?: false),
         true <-
           (Citation.valid?(source, incident, run) and
              FileReference.present_in?(source.content, intent["reference"])) ||
             {:error, "File reference is not present in the cited Case Evidence"},
         {:ok, bytes} <-
           Targets.read_bound_artifact_range(
             intent["reference"],
             intent["offset"],
             intent["length"],
             actor: actor
           ) do
      append(turn, intent, source, actor, bytes)
    else
      {:ok, false} -> {:error, "File-read Condition context changed"}
      error -> error
    end
  end

  defp append(turn, intent, source, actor, bytes) do
    key = "file-read:#{turn.id}"

    with {:ok, existing} <-
           Cases.evidence_by_idempotency(turn.case_id, key,
             authorize?: false,
             not_found_error?: false
           ),
         content <- receipt(intent, source, bytes),
         provenance <-
           if(existing,
             do: Map.take(existing.content, ["actor_id", "actor_role_version"]),
             else: %{"actor_id" => actor.id, "actor_role_version" => actor.role_version}
           ),
         {:ok, evidence} <-
           Cases.append_evidence(
             turn.case_id,
             turn.resolution_run_id,
             turn.id,
             key,
             "file_read",
             "file_store",
             turn.id,
             Map.merge(content, provenance),
             if(existing, do: existing.observed_at, else: DateTime.utc_now()),
             actor: actor,
             authorize?: false
           ) do
      evidence
    end
  end

  defp read(%{id: id, case_id: case_id}) do
    with {:ok, evidence} <- Cases.get_evidence(id, authorize?: false),
         true <-
           (evidence.kind == "file_read" and evidence.case_id == case_id) ||
             {:error, "File-read Evidence does not belong to this Case"},
         {:ok, {incident, run, actor}} <-
           current_context(case_id, evidence.resolution_run_id),
         content <- evidence.content,
         :ok <-
           valid_range(
             content["reference"],
             content["offset"],
             content["requested_length"],
             incident
           ),
         {:ok, source} <- Cases.get_evidence(content["source_evidence_id"], authorize?: false),
         true <-
           (Citation.valid?(source, incident, run) and
              FileReference.present_in?(source.content, content["reference"])) ||
             {:error, "File-read source Evidence is unavailable"},
         {:ok, bytes} <-
           Targets.read_bound_artifact_range(
             content["reference"],
             content["offset"],
             content["requested_length"],
             actor: actor
           ),
         expected <-
           receipt(
             %{
               "reference" => content["reference"],
               "offset" => content["offset"],
               "length" => content["requested_length"],
               "source_evidence_id" => content["source_evidence_id"],
               "reason" => content["reason"]
             },
             source,
             bytes
           ),
         true <-
           Map.take(content, Map.keys(expected)) == expected ||
             {:error, "File-read Evidence integrity check failed"} do
      if String.valid?(bytes),
        do: Map.merge(content, %{"encoding" => "utf8", "value" => bytes}),
        else: Map.merge(content, %{"encoding" => "base64", "value" => Base.encode64(bytes)})
    end
  end

  defp receipt(intent, source, bytes) do
    next = intent["offset"] + byte_size(bytes)

    %{
      "target_id" => intent["reference"]["target_id"],
      "source_evidence_id" => intent["source_evidence_id"],
      "source_observed_at" =>
        if(source.kind == "file_read",
          do: source.content["source_observed_at"],
          else: DateTime.to_iso8601(source.observed_at)
        ),
      "reference" => intent["reference"],
      "offset" => intent["offset"],
      "requested_length" => intent["length"],
      "byte_count" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "next_offset" => next,
      "eof" => next == intent["reference"]["size_bytes"],
      "reason" => intent["reason"]
    }
  end

  defp current_context(case_id, run_id) do
    with {:ok, incident} <-
           Case
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(id == ^case_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(authorize?: false, not_found_error?: true),
         true <-
           (incident.status == :running and not incident.cancel_requested) ||
             {:error, "Case is not running"},
         {:ok, run} <- Cases.get_resolution_run(run_id, authorize?: false),
         true <-
           (run.case_id == incident.id and run.active and run.status == :running and
              DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt) ||
             {:error, "File-read ResolutionRun is not current"},
         {:ok, actor} <- Accounts.get_user(incident.current_owner_id, authorize?: false),
         true <-
           actor.role in [:admin, :operator] || {:error, "Case owner cannot read file contents"},
         {:ok, target} <- Targets.get_target(incident.selected_target_id, authorize?: false),
         true <-
           (target.active and target.revision == incident.selected_target_revision) ||
             {:error, "File-read Target changed"} do
      {:ok, {incident, run, actor}}
    end
  end

  defp valid_range(reference, offset, length, incident) do
    if FileReference.valid?(reference) and reference["target_id"] == incident.selected_target_id and
         is_integer(offset) and offset >= 0 and offset <= reference["size_bytes"] and
         is_integer(length) and length in 1..AI.file_read_bytes(),
       do: :ok,
       else: {:error, "File-read reference, Target or range is invalid"}
  end
end
