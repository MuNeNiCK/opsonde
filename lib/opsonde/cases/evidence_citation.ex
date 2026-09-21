defmodule Opsonde.Cases.EvidenceCitation do
  @moduledoc false

  alias Opsonde.Cases

  def valid?(%{case_id: case_id, resolution_run_id: run_id}, %{id: case_id}, %{id: run_id}),
    do: true

  def valid?(
        %{
          case_id: case_id,
          kind: "signal_event",
          source_ref: source_ref,
          content: %{"current" => true, "state" => state}
        } = evidence,
        %{id: case_id, source_ref: source_ref, alert_state: alert_state},
        _run
      ) do
    state == to_string(alert_state) and latest_source_evidence?(evidence, case_id, source_ref)
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

  defp latest_source_evidence?(evidence, case_id, source_ref) do
    case Cases.source_context_evidence(case_id, source_ref, authorize?: false) do
      {:ok, [%{id: id} | _rest]} -> id == evidence.id
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
