defmodule Opsonde.Cases.Evidence.Projection do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Providers.AI

  def bound_review_context(request) do
    required_ids =
      MapSet.new(
        Map.get(request, :recovery_evidence_ids, []) ++
          Enum.flat_map(
            request.conditions,
            &(&1.recovery_evidence_ids ++ &1.failed_observation_ids)
          )
      )

    {required, optional} =
      Enum.split_with(request.context_evidence, &MapSet.member?(required_ids, &1.id))

    base = %{request | context_evidence: required}
    required_size = AI.input_size(base)

    if required_size <= AI.max_input_bytes() do
      maximum = min(AI.max_input_bytes(), required_size + AI.optional_context_bytes())

      Enum.reduce(optional, base, fn item, current ->
        candidate = %{current | context_evidence: current.context_evidence ++ [item]}

        if AI.input_size(candidate) <= maximum and review_items(candidate) <= 100,
          do: candidate,
          else: current
      end)
    else
      base
    end
  end

  defp review_items(request) do
    length(request.conditions) + length(request.source_evidence) + length(request.cited_evidence) +
      length(request.context_evidence) + length(Map.get(request, :target_relations, []))
  end

  def recent(case_id, cited_ids) do
    with {:ok, evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok, project(evidence, cited_ids)}
    end
  end

  def recent(case_id, target_id, cited_ids) do
    with {:ok, target_evidence} <-
           Cases.review_target_context_evidence(case_id, target_id, authorize?: false),
         :ok <- complete_target_context(target_evidence),
         {:ok, case_evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok,
       (chronology_anchors(target_evidence) ++ target_evidence ++ case_evidence)
       |> project(cited_ids)}
    end
  end

  defp complete_target_context(target_evidence) when length(target_evidence) <= 100, do: :ok

  defp complete_target_context(_target_evidence),
    do: {:error, :review_context_incomplete}

  defp project(evidence, cited_ids) do
    excluded = MapSet.new(cited_ids)

    evidence
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&MapSet.member?(excluded, &1.id))
    |> Enum.uniq_by(&context_identity/1)
    |> Enum.take(32)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.map(fn item ->
      %AI.Evidence{
        id: item.id,
        kind: item.kind,
        target_id: item.content["target_id"],
        observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
        content: item.content
      }
    end)
  end

  def file_contents(incident, run, evidence) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, loaded} ->
      if item.kind == "file_read" and file_target_id(item) == incident.selected_target_id do
        case file_content(item, incident, run) do
          {:ok, content} -> {:cont, {:ok, [%{item | content: content} | loaded]}}
          {:error, _error} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, [item | loaded]}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp file_content(item, incident, run) do
    with {:ok, stored} <- Cases.get_evidence(item.id, authorize?: false),
         true <-
           stored.case_id == incident.id || {:error, "File-read Evidence belongs to another Case"} do
      if stored.resolution_run_id == run.id do
        Cases.read_file_content(item.id, incident.id, authorize?: false)
      else
        {:ok,
         stored.content
         |> Map.drop(["value", "encoding"])
         |> Map.put("original_status", stored.content["status"])
         |> Map.put("status", "historical")
         |> Map.put("resolution_run_id", stored.resolution_run_id)}
      end
    end
  end

  defp file_target_id(%AI.Evidence{target_id: id}), do: id
  defp file_target_id(%Cases.Evidence{content: content}), do: content["target_id"]

  defp context_identity(%{kind: "file_read", id: id}), do: {"file_read", id}

  defp context_identity(item) do
    {item.content["target_id"], item.content["operation"], item.kind, item.content["status"],
     item.content["selectors"], item.content["parameters"], item.content["facts"],
     item.content["reference"]}
  end

  defp chronology_anchors(target_evidence) do
    case Enum.find(target_evidence, fn item ->
           item.kind == "operation_outcome" and item.content["status"] == "applied"
         end) do
      nil ->
        []

      effect ->
        prior_success =
          Enum.find(target_evidence, fn item ->
            item.kind in ["observation", "target_verification"] and
              item.content["status"] in ["applied", "verified"] and
              DateTime.compare(item.observed_at, effect.observed_at) == :lt
          end)

        later_failure =
          Enum.find(target_evidence, fn item ->
            item.kind in ["observation", "target_verification"] and
              item.content["status"] == "failed" and
              DateTime.compare(item.observed_at, effect.observed_at) == :gt
          end)

        Enum.reject([prior_success, effect, later_failure], &is_nil/1)
    end
  end
end
