defmodule Opsonde.Reports.Report.Document do
  @moduledoc false
  use Gettext, backend: Opsonde.Gettext

  alias Opsonde.Reports.Report

  def build(%Report{} = report) do
    content = report.content
    incident = map(content["case"])
    operations = list(content["operations"])
    evidence = list(content["raw_evidence"])
    verifications = list(content["verifications"])
    recovery_reviews = list(content["recovery_reviews"])
    conclusion_turn = accepted_conclusion_turn(incident, content, recovery_reviews)
    conclusion = conclusion_turn && map(conclusion_turn["decision"])
    cited = conclusion |> map() |> Map.get("evidence_ids") |> list()
    claims = conclusion |> map() |> Map.get("condition_claims") |> list()

    document = %{
      "title" => incident["title"],
      "outcome" => content["outcome_label"],
      "opened_at" => incident["inserted_at"],
      "finished_at" => incident["resolved_at"] || incident["updated_at"],
      "target_id" => incident["selected_target_id"] || incident["initial_target_id"],
      "source" => incident["source"],
      "source_ref" => incident["source_ref"],
      "severity" => incident["severity"],
      "conditions" => monitored_conditions(list(content["conditions"]), evidence, claims),
      "actions" =>
        Enum.filter(operations, &(&1["request_kind"] == "effect")) |> Enum.map(&action/1),
      "verifications" => Enum.map(verifications, &verification/1),
      "cited_evidence" => cited_evidence(cited, evidence),
      "conclusion" => conclusion && nonblank(conclusion["reason"]),
      "conclusion_turn_id" => conclusion_turn && conclusion_turn["id"],
      "recovery_reviews" => recovery_reviews,
      "stop_reason" => nonblank(get_in(content, ["unresolved", "stop_reason"])),
      "required_human_input" => nonblank(get_in(content, ["unresolved", "required_human_input"])),
      "case_id" => report.case_id,
      "case_revision" => report.case_revision,
      "digest" => report.content_digest
    }

    Map.put(document, "text", render_text(document, report.language))
  end

  defp accepted_conclusion_turn(%{"status" => "resolved"}, content, recovery_reviews) do
    turn_id = content["resolution_turn_id"]
    review_id = content["resolution_review_event_id"]

    if Enum.any?(recovery_reviews, fn review ->
         review["id"] == review_id and review["source_turn_id"] == turn_id and
           review["verdict"] == "approved"
       end) do
      Enum.find(list(content["resolver_turns"]), fn turn ->
        decision = map(turn["decision"])
        turn["id"] == turn_id and decision["type"] == "recovery_conclusion"
      end)
    end
  end

  defp accepted_conclusion_turn(_incident, _content, _recovery_reviews), do: nil

  defp monitored_conditions(conditions, evidence, claims) do
    Enum.map(conditions, fn condition ->
      id = condition["id"]

      source_events =
        Enum.filter(evidence, fn item ->
          item["kind"] == "signal_event" and get_in(item, ["content", "condition_id"]) == id
        end)

      first_firing =
        Enum.find(source_events, &(get_in(&1, ["content", "state"]) == "firing")) ||
          List.first(source_events)

      claim =
        Enum.find(claims, &(&1["condition_id"] == id and &1["revision"] == condition["revision"]))

      citation = claim && Enum.find(evidence, &(&1["id"] == claim["evidence_id"]))

      attributes =
        first_firing |> map() |> Map.get("content") |> map() |> Map.get("attributes") |> map()

      %{
        "id" => id,
        "target_id" => condition["target_id"],
        "predicate" => condition["predicate"],
        "source_state" => condition["state"],
        "symptom" => symptom(first_firing, attributes, condition),
        "source_evidence_id" => first_firing && first_firing["id"],
        "assessment" => claim && nonblank(claim["reason"]),
        "evidence_id" => citation && citation["id"],
        "evidence_facts" => citation && evidence_facts(citation)
      }
    end)
  end

  defp symptom(first_firing, attributes, condition) do
    labels = attributes["labels"] |> map() |> facts_text()
    title = nonblank(attributes["title"])
    native = first_firing && nonblank(first_firing["source_ref"])

    [title || native || nonblank(condition["predicate"]), labels]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp cited_evidence(ids, evidence) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Enum.find(evidence, &(&1["id"] == id)) do
        nil ->
          []

        item ->
          [
            %{
              "id" => id,
              "kind" => item["kind"],
              "observed_at" => item["observed_at"],
              "facts" => evidence_facts(item)
            }
          ]
      end
    end)
  end

  defp evidence_facts(item) do
    item
    |> Map.get("content")
    |> map()
    |> Map.get("facts")
    |> map()
    |> facts_text()
  end

  defp action(item) do
    result_details = map(item["result_details"])

    %{
      "id" => item["id"],
      "name" => action_name(item),
      "status" => item["status"],
      "outcome_category" => nonblank(item["outcome_category"]),
      "detail" =>
        nonblank(result_details["uncertainty"]) || nonblank(result_details["message"]) ||
          nonblank(result_details["reason"]),
      "completed_at" => item["completed_at"]
    }
  end

  defp verification(item) do
    %{
      "id" => item["id"],
      "status" => item["status"],
      "outcome_category" => nonblank(item["outcome_category"]),
      "facts" => facts_text(map(item["facts"])),
      "observed_at" => item["observed_at"]
    }
  end

  defp render_text(document, locale) do
    Gettext.with_locale(Opsonde.Gettext, Atom.to_string(locale), fn ->
      unknown = dgettext("reports", "Not established")

      lines = [
        document["title"],
        "#{dgettext("reports", "Outcome")}: #{document["outcome"]}",
        "#{dgettext("reports", "Target")}: #{document["target_id"] || unknown}",
        "#{dgettext("reports", "Source")}: #{document["source"] || unknown} / #{document["source_ref"] || unknown}",
        "#{dgettext("reports", "Severity")}: #{document["severity"] || unknown}",
        "#{dgettext("reports", "Opened at")}: #{document["opened_at"] || unknown}",
        "#{dgettext("reports", "Finished at")}: #{document["finished_at"] || unknown}",
        "",
        dgettext("reports", "Monitored conditions"),
        entries(
          document["conditions"],
          fn condition ->
            "• #{condition["symptom"]} [#{condition["source_state"]}] (#{condition["id"]})" <>
              if(condition["source_evidence_id"],
                do: " · #{dgettext("reports", "Evidence")}: #{condition["source_evidence_id"]}",
                else: ""
              ) <>
              if(condition["assessment"],
                do:
                  "\n  #{condition["assessment"]} · #{dgettext("reports", "Evidence")}: #{condition["evidence_id"]}" <>
                    if(condition["evidence_facts"],
                      do: " · #{condition["evidence_facts"]}",
                      else: ""
                    ),
                else: "\n  #{unknown}"
              )
          end,
          unknown
        ),
        "",
        dgettext("reports", "Actions"),
        entries(
          document["actions"],
          fn item ->
            "• #{item["name"]} (#{status_label(item["status"])})" <>
              if(item["detail"], do: " · #{item["detail"]}", else: "") <>
              " (#{item["id"]})"
          end,
          unknown
        ),
        "",
        dgettext("reports", "Target verification"),
        entries(
          document["verifications"],
          fn item ->
            "• #{status_label(item["status"])}: #{item["facts"] || unknown} (#{item["id"]})"
          end,
          unknown
        ),
        "",
        dgettext("reports", "Resolver assessment"),
        document["conclusion"] || unknown,
        if(document["conclusion_turn_id"],
          do: "#{dgettext("reports", "Turn")}: #{document["conclusion_turn_id"]}"
        ),
        dgettext("reports", "Cited evidence"),
        entries(
          document["cited_evidence"],
          fn item ->
            "• #{item["id"]} (#{item["kind"]}): #{item["facts"] || unknown}"
          end,
          unknown
        ),
        dgettext("reports", "Recovery reviews"),
        entries(
          document["recovery_reviews"],
          fn review ->
            "• #{review["verdict"]}: #{review["reason"]} (#{review["id"]})" <>
              "\n  #{dgettext("reports", "Evidence")}: #{Enum.join(list(review["evidence_ids"]), ", ")}"
          end,
          unknown
        ),
        "",
        dgettext("reports", "Unresolved items"),
        document["stop_reason"] || unknown,
        document["required_human_input"],
        "",
        "#{dgettext("reports", "Case")}: #{document["case_id"]} r#{document["case_revision"]}",
        "SHA-256: #{document["digest"]}"
      ]

      lines |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    end)
  end

  defp entries([], _render, unknown), do: unknown
  defp entries(items, render, _unknown), do: Enum.map(items, render)

  defp status_label("queued"), do: dgettext("reports", "Queued")
  defp status_label("dispatching"), do: dgettext("reports", "In progress")
  defp status_label("applied"), do: dgettext("reports", "Applied")
  defp status_label("failed"), do: dgettext("reports", "Failed")
  defp status_label("partial"), do: dgettext("reports", "Partial")
  defp status_label("unknown"), do: dgettext("reports", "Unknown")
  defp status_label("verified"), do: dgettext("reports", "Verified")
  defp status_label("not_verified"), do: dgettext("reports", "Not verified")
  defp status_label(value), do: value

  defp action_name(item) do
    parameters = map(item["parameters"])

    named =
      [parameters["kind"], parameters["name"], parameters["action"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    fallback =
      [item["capability"], item["operation"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" / ")

    method_path =
      with method when is_binary(method) <- parameters["method"],
           path when is_binary(path) <- parameters["path"] do
        String.upcase(method) <> " " <> path
      else
        _ -> nil
      end

    nonblank(parameters["command"]) || nonblank(named) || nonblank(method_path) ||
      nonblank(fallback) || "Operation"
  end

  defp facts_text(facts) when map_size(facts) == 0, do: nil

  defp facts_text(facts) do
    facts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> "#{key}=#{value(value)}" end)
    |> Enum.join(" · ")
    |> nonblank()
  end

  defp value(item) when is_binary(item), do: item
  defp value(item) when is_number(item) or is_boolean(item), do: to_string(item)
  defp value(item), do: Jason.encode!(item)

  defp nonblank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp nonblank(_value), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
