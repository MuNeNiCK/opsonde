defmodule Opsonde.Cases.RecoveryReviewFingerprint do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Cases.AIInvocation

  def current(incident, intent) do
    cited_ids = intent["evidence_ids"]

    with {:ok, source} <- source_evidence(incident) do
      {:ok, digest(cited_ids, intent["condition_claims"], source)}
    end
  end

  def reviewed(request) do
    digest(
      request.conclusion.evidence_ids,
      request.conclusion.condition_claims,
      request.source_evidence
    )
  end

  defp source_evidence(%{trigger_kind: :signal} = incident),
    do: Cases.signal_context_evidence(incident.id, authorize?: false)

  defp source_evidence(_incident), do: {:ok, []}

  defp digest(cited_ids, claims, source) do
    AIInvocation.request_digest(%{
      cited_ids: Enum.sort(cited_ids),
      claims:
        claims
        |> Enum.map(&Map.take(&1, ["condition_id", "revision", "evidence_id"]))
        |> Enum.sort_by(& &1["condition_id"]),
      source_ids: source |> Enum.map(& &1.id) |> Enum.sort()
    })
  end
end
