defmodule Opsonde.Reports.Report.Document do
  @moduledoc false
  use Gettext, backend: Opsonde.Gettext

  alias Opsonde.Reports.Report

  @condition_keys ~w(name unit active_state sub_state replicas ready_replicas available_replicas status state health ready phase)
  @verification_keys ~w(active_state sub_state status state health ready phase)

  def build(%Report{} = report) do
    content = report.content
    incident = map(content["case"])
    operations = list(content["operations"])
    proposals = list(content["proposals"])
    evidence = list(content["raw_evidence"])
    verifications = list(content["verifications"])
    effects = Enum.filter(operations, &(&1["request_kind"] == "effect"))
    final_applied = Enum.find(Enum.reverse(effects), &(&1["status"] == "applied"))
    proposal = Enum.find(proposals, &(&1["id"] == (final_applied || %{})["proposal_id"]))
    cited = MapSet.new(list((proposal || %{})["evidence_ids"]))

    condition =
      evidence
      |> Enum.filter(&MapSet.member?(cited, &1["id"]))
      |> Enum.reverse()
      |> Enum.find_value(fn item ->
        facts = item |> Map.get("content") |> map() |> Map.get("facts") |> map()

        case facts_text(facts, @condition_keys) do
          nil -> nil
          text -> %{"text" => text, "evidence_id" => item["id"]}
        end
      end)

    action_items =
      Enum.map(effects, fn item ->
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
      end)

    verification_items =
      Enum.map(verifications, fn item ->
        facts = facts_text(map(item["facts"]), @verification_keys)

        %{
          "id" => item["id"],
          "status" => item["status"],
          "outcome_category" => nonblank(item["outcome_category"]),
          "facts" => facts,
          "observed_at" => item["observed_at"]
        }
      end)

    recovery_observation =
      with %{"completed_at" => completed_at} when is_binary(completed_at) <- final_applied do
        evidence
        |> Enum.reverse()
        |> Enum.find_value(fn item ->
          facts = item |> Map.get("content") |> map() |> Map.get("facts") |> map()

          if item["kind"] == "observation" and is_binary(item["observed_at"]) and
               item["observed_at"] > completed_at and map_size(facts) > 0 do
            %{
              "evidence_id" => item["id"],
              "facts" =>
                facts_text(facts, @verification_keys) || facts_text(facts, Map.keys(facts)),
              "observed_at" => item["observed_at"]
            }
          end
        end)
      else
        _ -> nil
      end

    conclusion_turn =
      content["resolver_turns"]
      |> list()
      |> Enum.reverse()
      |> Enum.find_value(fn turn ->
        decision = map(turn["decision"])

        if decision["type"] == "recovery_conclusion" and nonblank(decision["reason"]),
          do: turn
      end)

    unresolved = map(content["unresolved"])

    document = %{
      "title" => incident["title"],
      "outcome" => content["outcome_label"],
      "opened_at" => incident["inserted_at"],
      "finished_at" => incident["updated_at"],
      "target_id" => incident["selected_target_id"] || incident["initial_target_id"],
      "source" => incident["source"],
      "source_ref" => incident["source_ref"],
      "severity" => incident["severity"],
      "condition" => condition,
      "actions" => action_items,
      "verifications" => verification_items,
      "recovery_observation" => recovery_observation,
      "conclusion" => conclusion_turn && map(conclusion_turn["decision"])["reason"],
      "conclusion_turn_id" => conclusion_turn && conclusion_turn["id"],
      "stop_reason" => nonblank(unresolved["stop_reason"]),
      "required_human_input" => nonblank(unresolved["required_human_input"]),
      "case_id" => report.case_id,
      "case_revision" => report.case_revision,
      "digest" => report.content_digest
    }

    Map.put(document, "text", render_text(document, report.language))
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
        dgettext("reports", "Observed condition"),
        (document["condition"] || %{})["text"] || unknown,
        if(document["condition"],
          do: "#{dgettext("reports", "Evidence")}: #{document["condition"]["evidence_id"]}"
        ),
        "",
        dgettext("reports", "Actions"),
        entries(
          document["actions"],
          fn item ->
            "• #{item["name"]} (#{status_label(item["status"])})#{if item["outcome_category"], do: " · #{item["outcome_category"]}"}#{if item["detail"], do: " · #{item["detail"]}"}"
          end,
          unknown
        ),
        "",
        dgettext("reports", "Recovery verification"),
        entries(
          document["verifications"],
          fn item ->
            "• #{status_label(item["status"])}: #{item["facts"] || unknown}#{if item["outcome_category"], do: " · #{item["outcome_category"]}"} (#{item["id"]})"
          end,
          unknown
        ),
        if(document["recovery_observation"],
          do:
            "• #{dgettext("reports", "Post-action observation")}: #{document["recovery_observation"]["facts"]} (#{document["recovery_observation"]["evidence_id"]})"
        ),
        "",
        dgettext("reports", "Resolver assessment"),
        document["conclusion"] || unknown,
        if(document["conclusion_turn_id"],
          do: "#{dgettext("reports", "Turn")}: #{document["conclusion_turn_id"]}"
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

  defp facts_text(facts, keys) do
    keys
    |> Enum.filter(&Map.has_key?(facts, &1))
    |> Enum.map(fn key -> "#{key}=#{value(facts[key])}" end)
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
