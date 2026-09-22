defmodule Opsonde.Cases.EvidenceCitation do
  @moduledoc false

  alias Opsonde.Cases

  def valid?(%{case_id: case_id, resolution_run_id: run_id}, %{id: case_id}, %{id: run_id}),
    do: true

  def valid?(
        %{
          case_id: case_id,
          kind: "signal_event",
          content: %{"current" => true}
        } = evidence,
        %{id: case_id},
        _run
      ) do
    latest_source_evidence?(evidence, case_id)
  end

  def valid?(
        %{
          case_id: case_id,
          kind: "target_verification",
          source: "verification",
          content: %{
            "status" => "verified",
            "operation_id" => operation_id,
            "target_id" => target_id
          }
        } = evidence,
        %{
          id: case_id,
          selected_target_id: target_id,
          selected_target_revision: target_revision
        },
        _run
      ) do
    latest_target_evidence?(evidence, case_id, target_id) and
      verified_operation?(operation_id, case_id, target_id, target_revision)
  end

  def valid?(_evidence, _incident, _run), do: false

  defp latest_source_evidence?(evidence, case_id) do
    case Cases.signal_context_evidence(case_id, authorize?: false) do
      {:ok, candidates} -> Enum.any?(candidates, &(&1.id == evidence.id))
      _unavailable -> false
    end
  end

  defp latest_target_evidence?(evidence, case_id, target_id) do
    case Cases.target_continuity_evidence(case_id, authorize?: false) do
      {:ok, candidates} ->
        case Enum.find(candidates, &(&1.content["target_id"] == target_id)) do
          %{id: id} -> id == evidence.id
          _unavailable -> false
        end

      _unavailable ->
        false
    end
  end

  defp verified_operation?(operation_id, case_id, target_id, target_revision) do
    case Cases.get_operation(operation_id, authorize?: false) do
      {:ok,
       %{
         case_id: ^case_id,
         target_id: ^target_id,
         target_revision: ^target_revision,
         status: :applied
       }} ->
        true

      _unavailable ->
        false
    end
  end
end
