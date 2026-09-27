defmodule Opsonde.Cases.ReviewerEvidence do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Providers.AI

  def recent(case_id, cited_ids) do
    with {:ok, evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok, project(evidence, cited_ids)}
    end
  end

  def recent(case_id, target_id, cited_ids) do
    with {:ok, target_evidence} <-
           Cases.review_target_context_evidence(case_id, target_id, authorize?: false),
         {:ok, case_evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok,
       (chronology_anchors(target_evidence) ++ target_evidence ++ case_evidence)
       |> project(cited_ids)}
    end
  end

  defp project(evidence, cited_ids) do
    excluded = MapSet.new(cited_ids)

    evidence
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&MapSet.member?(excluded, &1.id))
    |> Enum.uniq_by(fn item ->
      {item.content["target_id"], item.content["operation"], item.kind, item.content["status"],
       item.content["selectors"], item.content["parameters"], item.content["facts"],
       item.content["reference"]}
    end)
    |> Enum.take(32)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.map(fn item ->
      %AI.Evidence{
        id: item.id,
        kind: item.kind,
        target_id: item.content["target_id"],
        observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
        content: project_content(item.content)
      }
    end)
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

  def project_content(%{"facts" => facts, "details" => details} = content)
      when is_map(facts) and is_map(details) do
    if details["facts"] == facts and
         Enum.all?(Map.keys(details), &(&1 in ~w(facts evidence observed_at))) do
      content
      |> Map.delete("details")
      |> Map.put("details_compacted", true)
    else
      content
    end
  end

  def project_content(content), do: content
end
