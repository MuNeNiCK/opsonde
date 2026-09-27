defmodule Opsonde.Cases.ReviewerEvidence do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Providers.AI

  def recent(case_id, cited_ids) do
    excluded = MapSet.new(cited_ids)

    with {:ok, evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok,
       evidence
       |> Enum.reject(&MapSet.member?(excluded, &1.id))
       |> Enum.uniq_by(fn item ->
         {item.content["target_id"], item.content["operation"], item.kind, item.content["status"],
          item.content["selectors"], item.content["parameters"], item.content["facts"],
          item.content["reference"]}
       end)
       |> Enum.take(32)
       |> Enum.map(fn item ->
         %AI.Evidence{
           id: item.id,
           kind: item.kind,
           target_id: item.content["target_id"],
           observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
           content: project_content(item.content)
         }
       end)}
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
