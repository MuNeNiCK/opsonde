defmodule Opsonde.Cases.CaseSymptom do
  @moduledoc false

  alias Opsonde.Providers.AI

  def current(%{id: id, trigger_kind: kind, title: title, initial_context: context})
      when kind in [:manual, :audit] and is_binary(id) and is_map(context) do
    text =
      case kind do
        :audit -> preferred(context["objective"], title)
        :manual -> preferred(context["symptom"], title)
      end

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({id, kind, text}, [:deterministic]))
      |> Base.encode16(case: :lower)

    %{id: digest, text: text}
  end

  def current(_incident), do: nil

  def valid?(nil), do: true

  def valid?(%{id: id, text: text}) do
    is_binary(id) and byte_size(id) == 64 and String.match?(id, ~r/\A[0-9a-f]{64}\z/) and
      is_binary(text) and byte_size(text) <= 8_000 and String.trim(text) != "" and
      String.length(text) <= 2_000
  end

  def valid?(_symptom), do: false

  def valid_claims?([], nil, _cited_ids, _evidence), do: true

  def valid_claims?(claims, %{id: symptom_id}, cited_ids, evidence)
      when is_list(claims) and is_list(cited_ids) and is_list(evidence) do
    by_id = Map.new(evidence, &{&1.id, &1})

    length(claims) in 1..3 and
      Enum.all?(claims, fn claim ->
        if is_map(claim) and
             Enum.sort(Map.keys(claim)) == ~w(evidence_id fact_keys reason symptom_id) do
          item = Map.get(by_id, claim["evidence_id"])
          keys = claim["fact_keys"]
          facts = if item && is_map(item.content), do: item.content["facts"], else: nil

          claim["symptom_id"] == symptom_id and claim["evidence_id"] in cited_ids and
            not is_nil(item) and item.kind in ["observation", "target_verification"] and
            is_map(facts) and is_list(keys) and length(keys) in 1..5 and
            length(Enum.uniq(keys)) == length(keys) and
            Enum.all?(keys, &(is_binary(&1) and Map.has_key?(facts, &1))) and
            AI.valid_resolver_reason?(claim["reason"])
        else
          false
        end
      end)
  end

  def valid_claims?(_claims, _symptom, _cited_ids, _evidence), do: false

  defp preferred(value, fallback)
       when is_binary(value) and byte_size(value) <= 8_000 do
    if String.trim(value) != "" and String.length(value) <= 2_000,
      do: value,
      else: fallback
  end

  defp preferred(_value, fallback), do: fallback
end
