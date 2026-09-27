defmodule Opsonde.Cases.ResolverProjection do
  @moduledoc false

  alias Opsonde.{Cases, Signals, Targets}
  alias Opsonde.Cases.ConditionRecovery
  alias Opsonde.Cases.TraversalBoundary
  alias Opsonde.Providers.AI
  alias Opsonde.Targets.OperationCatalog

  @diagnostic_text_limit 2_000

  @spec build(String.t(), AI.Selection.t(), map()) ::
          {:ok, AI.ResolverRequest.t()} | {:error, term()}
  def build(turn_id, selection, invocation \\ %{})

  def build(turn_id, %AI.Selection{role: :resolver} = selection, invocation) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
         :ok <- eligible(incident, run, turn),
         {:ok, evidence} <-
           Cases.resolver_evidence_window(incident.id, run.id, authorize?: false),
         {:ok, {conditions, recovery_ids}} <- current_condition_context(incident),
         {:ok, recovery_evidence} <- current_recovery_evidence(incident, recovery_ids),
         {:ok, source_context} <-
           source_context(incident, Enum.uniq_by(recovery_evidence ++ evidence, & &1.id)),
         {:ok, target} <- selected_target(incident),
         {:ok, historical_evidence} <- prior_run_evidence(incident, run, target),
         {:ok, recent_recovery_review} <- recent_recovery_review(incident),
         {:ok, continuity} <- target_continuity(incident, target, source_context),
         {:ok, {relations, traversable_relation_ids}} <- relations(target, incident, run, turn),
         {:ok, tools} <- tools(target, run, invocation, incident, conditions, continuity),
         request <-
           request(
             selection,
             incident,
             run,
             turn,
             conditions,
             recovery_ids,
             continuity,
             historical_evidence,
             recent_recovery_review,
             target,
             relations,
             traversable_relation_ids,
             tools
           ),
         :ok <- AI.Validator.validate_request(:resolve, request) do
      {:ok, request}
    end
  end

  def build(_turn_id, _selection, _invocation),
    do: {:error, "Resolver AI selection is invalid"}

  defp current_recovery_evidence(_incident, []), do: {:ok, []}

  defp current_recovery_evidence(incident, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, loaded} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, %{case_id: case_id, kind: kind} = item}
        when case_id == incident.id and kind in ["observation", "target_verification"] ->
          {:cont, {:ok, [item | loaded]}}

        _unavailable ->
          {:halt, {:error, "Current recovery Evidence is unavailable"}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp prior_run_evidence(_incident, _run, nil), do: {:ok, []}

  defp prior_run_evidence(incident, run, target) do
    with {:ok, evidence} <- Cases.review_context_evidence(incident.id, authorize?: false) do
      {:ok,
       evidence
       |> Enum.filter(fn item ->
         item.resolution_run_id != run.id and item.content["target_id"] == target.id
       end)
       |> Enum.uniq_by(fn item ->
         {item.kind, item.content["operation"], item.content["status"], item.content["selectors"],
          item.content["parameters"], item.content["facts"], item.content["reference"]}
       end)
       |> Enum.take(16)}
    end
  end

  defp recent_recovery_review(incident) do
    with {:ok, reviews} <- Cases.recovery_review_history(incident.id, authorize?: false) do
      case Enum.max_by(reviews, & &1.inserted_at, DateTime, fn -> nil end) do
        %{data: %{"verdict" => "rejected"} = data, inserted_at: reviewed_at} ->
          {:ok,
           data
           |> Map.take(["verdict", "reason", "evidence_ids", "condition_claims"])
           |> Map.put("reviewed_at", DateTime.to_iso8601(reviewed_at))}

        _other ->
          {:ok, nil}
      end
    end
  end

  defp eligible(incident, run, turn) do
    cond do
      incident.cancel_requested ->
        {:error, "Case cancellation was requested"}

      incident.status != :running ->
        {:error, "Case resolution is not running"}

      not run.active or run.status != :running ->
        {:error, "ResolutionRun is not running"}

      turn.case_id != incident.id ->
        {:error, "Turn belongs to another Case"}

      turn.resolution_run_id != run.id ->
        {:error, "Turn belongs to another ResolutionRun"}

      turn.status != :started ->
        {:error, "Turn is already finalized"}

      DateTime.compare(DateTime.utc_now(), run.deadline_at) in [:eq, :gt] ->
        {:error, "Resolution elapsed-time limit exhausted"}

      remaining(run.max_ai_usage_units, run.ai_usage_units) == 0 ->
        {:error, "AI usage limit exhausted"}

      true ->
        :ok
    end
  end

  def current_conditions(%{trigger_kind: :signal} = incident) do
    with {:ok, memberships} <-
           Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- memberships != [] || {:error, "Signal Case has no active Conditions"} do
      Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, collected} ->
        case Signals.get_condition(membership.condition_id, authorize?: false) do
          {:ok, condition} ->
            item = %AI.Condition{
              id: condition.id,
              revision: condition.revision,
              occurrence: condition.occurrence,
              predicate: condition.predicate,
              subject_key: condition.subject_key,
              subject_ref: condition.subject_ref,
              state: condition.state,
              target_id: condition.target_id,
              current_occurred_at_us:
                DateTime.to_unix(condition.current_occurred_at, :microsecond)
            }

            {:cont, {:ok, [item | collected]}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, collected} -> {:ok, Enum.reverse(collected)}
        error -> error
      end
    end
  end

  def current_conditions(_incident), do: {:ok, []}

  def current_condition_context(incident) do
    with {:ok, conditions} <- current_conditions(incident) do
      recovery_context(incident, conditions)
    end
  end

  def condition_revisions(conditions) do
    conditions
    |> Enum.map(&%{"id" => &1.id, "revision" => &1.revision})
    |> Enum.sort_by(& &1["id"])
  end

  def current_condition_revisions(incident) do
    with {:ok, conditions} <- current_conditions(incident) do
      {:ok, condition_revisions(conditions)}
    end
  end

  defp recovery_context(%{trigger_kind: :signal} = incident, conditions) do
    case ConditionRecovery.assess_current(incident) do
      {:ok, assessments} ->
        by_id = Map.new(assessments, &{&1.condition_id, &1})

        conditions =
          Enum.map(conditions, fn condition ->
            assessment = Map.fetch!(by_id, condition.id)

            %{
              condition
              | recovery_status: assessment.status,
                recovery_evidence_id: assessment.evidence_id
            }
          end)

        proof_ids =
          if ConditionRecovery.ready_for_review?(assessments),
            do: assessments |> Enum.map(& &1.evidence_id) |> Enum.uniq(),
            else: []

        {:ok, {conditions, proof_ids}}

      {:error, "Relevant Target effect is not complete"} ->
        {:ok, {conditions, []}}

      {:error, _error} = error ->
        error
    end
  end

  defp recovery_context(_incident, conditions), do: {:ok, {conditions, []}}

  defp selected_target(%{selected_target_id: nil, selected_target_revision: nil}), do: {:ok, nil}

  defp selected_target(incident) do
    with {:ok, target} <- Targets.get_target(incident.selected_target_id, authorize?: false),
         true <- target.active || {:error, "Selected Target is inactive"},
         true <-
           target.revision == incident.selected_target_revision ||
             {:error, "Selected Target revision changed"} do
      {:ok, target}
    end
  end

  defp source_context(%{trigger_kind: :signal} = incident, evidence) do
    with {:ok, candidates} <- Cases.signal_context_evidence(incident.id, authorize?: false) do
      {:ok, replace_source_context(evidence, candidates)}
    end
  end

  defp source_context(_incident, evidence), do: {:ok, evidence}

  defp replace_source_context(evidence, candidates) do
    current =
      Enum.filter(candidates, fn
        %{kind: "signal_event", content: %{"current" => true}} -> true
        _candidate -> false
      end)

    current ++ Enum.reject(evidence, &(&1.kind == "signal_event"))
  end

  defp target_continuity(incident, target, evidence) when not is_nil(target) do
    with {:ok, candidates} <-
           Cases.target_continuity_evidence(incident.id, authorize?: false) do
      latest =
        Enum.find(candidates, fn candidate ->
          candidate.content["target_id"] == target.id
        end)

      {:ok, prepend_verified_continuity(evidence, latest, incident, target)}
    end
  end

  defp target_continuity(_incident, _target, evidence), do: {:ok, evidence}

  defp prepend_verified_continuity(
         evidence,
         %{
           case_id: case_id,
           source: "verification",
           content: %{
             "status" => "verified",
             "operation_id" => operation_id,
             "target_id" => target_id
           }
         } = latest,
         %{id: case_id},
         %{id: target_id, revision: target_revision}
       ) do
    with false <- Enum.any?(evidence, &(&1.id == latest.id)),
         {:ok,
          %{
            case_id: ^case_id,
            target_id: ^target_id,
            target_revision: ^target_revision,
            status: :applied
          }} <- Cases.get_operation(operation_id, authorize?: false) do
      [latest | evidence]
    else
      _existing_or_stale -> evidence
    end
  end

  defp prepend_verified_continuity(evidence, _latest, _incident, _target), do: evidence

  defp relations(nil, _incident, _run, _turn), do: {:ok, {[], []}}

  defp relations(
         _target,
         _incident,
         %{max_related_targets: maximum, related_target_count: count},
         _turn
       )
       when count >= maximum,
       do: {:ok, {[], []}}

  defp relations(target, _incident, _run, turn) do
    with {:ok, relationships} <-
           Targets.adjacent_relationships_for_traversal(target.id, authorize?: false),
         {:ok, projected} <-
           relationships
           |> Enum.reject(&TraversalBoundary.immediate_reverse?(&1.id, turn.intent))
           |> Enum.reduce_while({:ok, []}, fn relationship, {:ok, projected} ->
             case relation(relationship, target) do
               {:ok, value} -> {:cont, {:ok, [value | projected]}}
               :skip -> {:cont, {:ok, projected}}
               {:error, error} -> {:halt, {:error, error}}
             end
           end) do
      projected = Enum.reverse(projected)

      {:ok,
       {Enum.map(projected, &elem(&1, 0)), for({relation, true} <- projected, do: relation.id)}}
    end
  end

  defp relation(relationship, target) do
    next_target_id =
      if relationship.source_target_id == target.id,
        do: relationship.destination_target_id,
        else: relationship.source_target_id

    case Targets.get_target(next_target_id, authorize?: false) do
      {:ok, %{active: true} = next_target} ->
        with {:ok, methods} <-
               Targets.available_access_methods_for_target(next_target.id,
                 authorize?: false
               ) do
          current = target_candidate(target)
          adjacent = target_candidate(next_target)

          {source, destination} =
            if relationship.source_target_id == target.id,
              do: {current, adjacent},
              else: {adjacent, current}

          {:ok,
           {%AI.TargetRelation{
              id: relationship.id,
              revision: relationship.revision,
              source_target: source,
              destination_target: destination,
              kind: relationship.kind,
              attributes: relationship.facts
            }, methods != []}}
        end

      _unavailable ->
        :skip
    end
  end

  defp target_candidate(target) do
    %AI.TargetCandidate{
      id: target.id,
      revision: target.revision,
      name: target.name,
      kind: target.kind,
      platform: target.platform,
      facts: target.facts
    }
  end

  defp tools(nil, _run, _invocation, _incident, _conditions, _evidence),
    do: {:ok, {[], []}}

  defp tools(target, run, invocation, incident, conditions, evidence) do
    if remaining(run.max_target_requests, run.target_request_count) == 0 and
         remaining(run.max_effects, run.effect_count) == 0 do
      {:ok, {[], []}}
    else
      with {:ok, methods} <-
             Targets.available_access_methods_for_target(target.id, authorize?: false),
           {:ok, methods} <-
             available_methods(methods, incident, run, target, conditions, evidence),
           {:ok, capabilities} <- OperationCatalog.for_methods(methods, invocation) do
        {:ok, build_tools(target, run, methods, capabilities)}
      end
    end
  end

  defp available_methods(methods, incident, run, target, conditions, evidence) do
    refreshed_at = source_refresh_at(evidence, run, target, conditions)

    Enum.reduce_while(methods, {:ok, []}, fn method, {:ok, available} ->
      case Cases.recent_method_observations(
             incident.id,
             run.id,
             target.id,
             method.id,
             method.revision,
             authorize?: false
           ) do
        {:ok, recent} ->
          if repeated_transport_failure?(recent, refreshed_at),
            do: {:cont, {:ok, available}},
            else: {:cont, {:ok, [method | available]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, available} -> {:ok, Enum.reverse(available)}
      error -> error
    end
  end

  defp repeated_transport_failure?(recent, refreshed_at) do
    recent
    |> Enum.take_while(fn operation ->
      operation.status == :failed and
        is_struct(operation.completed_at, DateTime) and
        (is_nil(refreshed_at) or DateTime.compare(operation.completed_at, refreshed_at) == :gt)
    end)
    |> Enum.count(&(&1.result_details["provider_category"] in ["retryable", "timeout"]))
    |> Kernel.>=(2)
  end

  defp source_refresh_at(evidence, run, target, conditions) do
    condition_ids =
      conditions
      |> Enum.filter(&(&1.target_id == target.id))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    evidence
    |> Enum.filter(fn item ->
      item.resolution_run_id == run.id and
        ((match?(%{"status" => "applied"}, item.content) and
            item.kind == "operation_outcome") or
           (item.kind == "signal_event" and
              MapSet.member?(condition_ids, item.content["condition_id"])))
    end)
    |> Enum.map(& &1.observed_at)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp build_tools(target, run, methods, capabilities) do
    observation? = remaining(run.max_target_requests, run.target_request_count) > 0
    proposal? = remaining(run.max_effects, run.effect_count) > 0

    Enum.reduce(methods, {[], []}, fn method, {observations, proposals} ->
      vocabulary = Map.fetch!(capabilities, method.id)

      method_observations =
        if observation?,
          do: operation_tools(:observation, target, method, vocabulary.observations),
          else: []

      observation_requests =
        if observation?,
          do: operation_tools(:request_observation, target, method, vocabulary.observations),
          else: []

      effect_requests =
        if proposal?,
          do: operation_tools(:request_effect, target, method, vocabulary.effects),
          else: []

      {observations ++ method_observations, proposals ++ observation_requests ++ effect_requests}
    end)
  end

  defp operation_tools(kind, target, method, operations) do
    operations
    |> Enum.filter(&(&1.capability in method.capabilities))
    |> Enum.sort_by(&{&1.capability, &1.operation})
    |> Enum.map(fn operation ->
      common_fields = %{
        id: tool_id(kind, method, operation),
        target_id: target.id,
        target_revision: target.revision,
        access_method_id: method.id,
        access_method_revision: method.revision,
        provider_id: method.provider_id,
        provider_revision: method.provider_revision,
        capability: operation.capability,
        operation: operation.operation,
        description: "Access Method #{method.name}: " <> operation.description,
        input_schema: operation.input_schema
      }

      case kind do
        :observation ->
          struct!(
            AI.ObservationTool,
            Map.merge(common_fields, %{
              output_schema: operation.output_schema,
              verification_schema: operation.verification_schema
            })
          )

        :request_observation ->
          struct!(
            AI.ProposalTool,
            common_fields
            |> Map.put(:request_kind, :observation)
            |> Map.put(:evidence_requirements, [])
          )

        :request_effect ->
          struct!(
            AI.ProposalTool,
            common_fields
            |> Map.put(:request_kind, :effect)
            |> Map.put(:evidence_requirements, operation.evidence_requirements)
          )
      end
    end)
  end

  defp tool_id(kind, method, operation) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {kind, method.id, method.revision, method.provider_id, method.provider_revision,
           operation.capability, operation.operation},
          [:deterministic]
        )
      )
      |> Base.url_encode64(padding: false)

    "#{kind}:#{digest}"
  end

  defp request(
         selection,
         incident,
         run,
         turn,
         conditions,
         recovery_ids,
         evidence,
         historical_evidence,
         recent_recovery_review,
         target,
         relations,
         traversable_relation_ids,
         {observations, proposals}
       ) do
    limits = AI.resolver_disclosure_limits()

    recovery_baseline =
      if incident.trigger_kind in [:manual, :audit] do
        case ConditionRecovery.baseline_for_case(incident) do
          {:ok, baseline} -> baseline
          {:error, _reason} -> nil
        end
      end

    base = %AI.ResolverRequest{
      provider_revision: selection.provider_revision,
      session_id: "resolver:#{run.id}",
      case_id: incident.id,
      turn: turn.ordinal,
      objective: objective(incident, turn, recent_recovery_review),
      alert_state: projected_alert_state(incident, conditions),
      report_language: incident.report_language,
      disclosure: %AI.Disclosure{
        allowed_target_ids: selected_target_ids(target),
        allowed_evidence_kinds: [],
        max_items: limits.max_items,
        max_bytes: limits.max_bytes
      },
      budget: budget(run, turn),
      conditions: conditions,
      evidence: [],
      historical_evidence: [],
      target_candidates: [],
      selected_target_id: target && target.id,
      selected_target_revision: target && target.revision,
      retry_context: retry_context(turn),
      observation_results: [],
      target_relations: [],
      traversable_relation_ids: [],
      observation_tools: [],
      proposal_tools: []
    }

    {source_evidence, other_evidence} =
      Enum.split_with(evidence, &(&1.kind == "signal_event"))

    manual_recovery_ids =
      if (incident.trigger_kind in [:manual, :audit] and target) &&
           is_struct(recovery_baseline, DateTime) do
        other_evidence
        |> Enum.filter(&manual_recovery_candidate?(&1, incident, run, target, recovery_baseline))
        |> Enum.map(& &1.id)
      else
        []
      end

    base
    |> add_items(
      :evidence,
      generic_evidence(
        source_evidence,
        base.disclosure.allowed_target_ids,
        incident,
        run,
        recovery_baseline
      )
    )
    |> add_mapped_condition_candidates(conditions)
    |> add_candidate_group(other_evidence)
    |> add_items(:target_relations, relations)
    |> add_items(:observation_tools, observations)
    |> add_items(:proposal_tools, proposals)
    |> then(fn current ->
      add_items(
        current,
        :evidence,
        generic_evidence(
          other_evidence,
          current.disclosure.allowed_target_ids,
          incident,
          run,
          recovery_baseline
        )
      )
    end)
    |> then(fn current ->
      current_ids = MapSet.new(Enum.map(current.evidence, & &1.id))

      add_items(
        current,
        :historical_evidence,
        generic_evidence(
          Enum.reject(historical_evidence, &MapSet.member?(current_ids, &1.id)),
          current.disclosure.allowed_target_ids,
          incident,
          run,
          recovery_baseline
        )
      )
    end)
    |> then(fn current ->
      %{current | proposal_tools: AI.available_proposal_tools(current)}
    end)
    |> normalize_disclosure()
    |> mark_recovery_proofs(recovery_ids ++ manual_recovery_ids)
    |> then(fn current ->
      visible_ids = MapSet.new(Enum.map(current.target_relations, & &1.id))

      %{
        current
        | traversable_relation_ids:
            Enum.filter(traversable_relation_ids, &MapSet.member?(visible_ids, &1))
      }
    end)
  end

  defp add_mapped_condition_candidates(request, conditions) do
    conditions
    |> Enum.map(& &1.target_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(request, fn target_id, current ->
      if target_id == current.selected_target_id or
           AI.target_candidate_evidence_ids(current, target_id) == [] or
           Enum.any?(current.target_candidates, &(&1.id == target_id)) do
        current
      else
        case Targets.get_target(target_id, authorize?: false) do
          {:ok, %{active: true} = target} ->
            case try_update(current, fn value ->
                   %{
                     value
                     | target_candidates: value.target_candidates ++ [target_candidate(target)]
                   }
                 end) do
              {:ok, updated} -> updated
              :full -> current
            end

          _unavailable ->
            current
        end
      end
    end)
  end

  defp mark_recovery_proofs(request, []), do: request

  defp mark_recovery_proofs(request, ids) do
    visible = MapSet.new(Enum.map(request.evidence, & &1.id))

    if Enum.all?(ids, &MapSet.member?(visible, &1)) do
      %{
        request
        | recovery_evidence_ids: ids
      }
    else
      request
    end
  end

  def projected_alert_state(%{trigger_kind: :signal}, conditions) do
    if conditions != [] and Enum.all?(conditions, &(&1.state == :recovered)),
      do: :recovered,
      else: :firing
  end

  def projected_alert_state(_incident, _conditions), do: :not_applicable

  defp objective(incident, turn, recent_recovery_review) do
    value = %{
      "case_title" => incident.title,
      "initial_context" => incident.initial_context,
      "turn_intent" => turn.intent
    }

    value =
      if is_map(recent_recovery_review),
        do: Map.put(value, "last_rejected_recovery_review", recent_recovery_review),
        else: value

    case Jason.encode(value) do
      {:ok, encoded} -> String.slice(encoded, 0, 8_000)
      {:error, _error} -> incident.title
    end
  end

  defp retry_context(%{
         intent: %{"source" => "resolver_delivery_failure", "category" => category} = intent
       }) do
    %{"category" => category}
    |> maybe_put_retry_code(intent["rejection_code"])
    |> maybe_put_retry_path(intent["rejection_path"])
  end

  defp retry_context(_turn), do: nil

  defp maybe_put_retry_code(context, code) when is_binary(code) and code != "",
    do: Map.put(context, "rejection_code", code)

  defp maybe_put_retry_code(context, _code), do: context

  defp maybe_put_retry_path(context, path) when is_binary(path) and path != "",
    do: Map.put(context, "rejection_path", path)

  defp maybe_put_retry_path(context, _path), do: context

  defp budget(run, turn) do
    %AI.Budget{
      remaining_turns: max(run.max_resolver_turns - turn.ordinal + 1, 0),
      remaining_tokens: remaining(run.max_ai_usage_units, run.ai_usage_units),
      remaining_target_requests: remaining(run.max_target_requests, run.target_request_count),
      remaining_effects: remaining(run.max_effects, run.effect_count),
      remaining_related_targets: remaining(run.max_related_targets, run.related_target_count)
    }
  end

  defp remaining(maximum, consumed), do: max(maximum - consumed, 0)

  defp add_candidate_group(request, evidence) do
    case Enum.find(evidence, &candidate_evidence?/1) do
      nil ->
        request

      item ->
        candidates = candidates(item)

        compact = %AI.Evidence{
          id: item.id,
          kind: item.kind,
          content: %{
            "query" => item.content["query"],
            "candidate_ids" => []
          }
        }

        case try_update(request, fn current ->
               %{current | evidence: current.evidence ++ [compact]}
             end) do
          {:ok, with_evidence} ->
            Enum.reduce(candidates, with_evidence, fn candidate, current ->
              result =
                try_update(current, fn value ->
                  updated_evidence =
                    Enum.map(value.evidence, fn
                      %{id: id} = evidence when id == compact.id ->
                        %{
                          evidence
                          | content: %{
                              evidence.content
                              | "candidate_ids" =>
                                  evidence.content["candidate_ids"] ++ [candidate.id]
                            }
                        }

                      evidence ->
                        evidence
                    end)

                  %{
                    value
                    | evidence: updated_evidence,
                      target_candidates: value.target_candidates ++ [candidate]
                  }
                end)

              case result do
                {:ok, updated} -> updated
                :full -> current
              end
            end)

          :full ->
            request
        end
    end
  end

  defp candidate_evidence?(%{kind: "target_candidates", source: "target_catalog"}), do: true
  defp candidate_evidence?(_evidence), do: false

  defp candidates(%{content: %{"targets" => values}}) when is_list(values) do
    values
    |> Enum.reduce([], fn
      %{
        "id" => id,
        "revision" => revision,
        "name" => name,
        "kind" => kind,
        "platform" => platform,
        "facts" => facts
      },
      loaded
      when is_binary(id) and is_integer(revision) and revision > 0 and is_binary(name) and
             is_binary(kind) and is_binary(platform) and is_map(facts) ->
        [
          %AI.TargetCandidate{
            id: id,
            revision: revision,
            name: name,
            kind: kind,
            platform: platform,
            facts: facts
          }
          | loaded
        ]

      _candidate, loaded ->
        loaded
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
  end

  defp candidates(_evidence), do: []

  defp generic_evidence(evidence, allowed_target_ids, incident, run, recovery_baseline) do
    evidence
    |> Enum.reject(&candidate_evidence?/1)
    |> compact_repeated_operations()
    |> Enum.map(fn item ->
      %AI.Evidence{
        id: item.id,
        kind: item.kind,
        target_id: evidence_target_id(item, allowed_target_ids),
        observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
        content: recovery_evidence_content(item, incident, run, recovery_baseline)
      }
    end)
  end

  defp recovery_evidence_content(evidence, _incident, _run, _baseline),
    do: projected_evidence_content(evidence)

  defp manual_recovery_candidate?(evidence, incident, run, target, baseline) do
    DateTime.compare(evidence.observed_at, baseline) != :lt and
      evidence.content["target_id"] == target.id and
      case evidence do
        %{
          kind: "observation",
          source_ref: operation_id,
          content: %{"status" => "applied", "category" => "target_observed", "facts" => facts}
        }
        when is_map(facts) and map_size(facts) > 0 ->
          case Cases.get_operation(operation_id, authorize?: false) do
            {:ok, operation} ->
              evidence.resolution_run_id == run.id and operation.case_id == incident.id and
                operation.resolution_run_id == run.id and
                operation.target_id == target.id and operation.target_revision == target.revision and
                operation.request_kind == :observation and operation.status == :applied and
                is_struct(operation.dispatch_started_at, DateTime) and
                DateTime.compare(operation.dispatch_started_at, baseline) != :lt

            _other ->
              false
          end

        %{
          kind: "target_verification",
          content: %{"status" => "verified", "operation_id" => operation_id}
        } ->
          with {:ok, operation} <- Cases.get_operation(operation_id, authorize?: false),
               {:ok, attempt} <-
                 Cases.verification_attempt_by_operation(operation_id, authorize?: false) do
            operation.case_id == incident.id and operation.target_id == target.id and
              operation.target_revision == target.revision and
              operation.request_kind == :effect and operation.status == :applied and
              attempt.status == :verified and attempt.case_id == incident.id and
              attempt.observed_at == evidence.observed_at
          else
            _other -> false
          end

        _other ->
          false
      end
  end

  defp projected_evidence_content(%{kind: kind, content: content})
       when kind in ["observation", "operation_outcome"] do
    facts = content["facts"]

    projected =
      Map.take(content, [
        "access_method_id",
        "capability",
        "category",
        "facts",
        "operation",
        "parameters",
        "reference",
        "request_kind",
        "selectors",
        "status",
        "target_id",
        "tool_id"
      ])

    if content["status"] != "applied" or not is_map(facts) or map_size(facts) == 0 do
      maybe_put_diagnostics(projected, content["details"])
    else
      projected
    end
  end

  defp projected_evidence_content(%{kind: "target_verification", content: content}) do
    Map.take(content, [
      "access_method_id",
      "category",
      "expected",
      "facts",
      "operation_id",
      "status",
      "target_id"
    ])
  end

  defp projected_evidence_content(%{content: content}), do: content

  defp maybe_put_diagnostics(projected, details) when is_map(details) do
    diagnostics =
      details
      |> Map.take(["exit_status", "message"])
      |> maybe_put_stream("stderr", details["stderr"])
      |> maybe_put_stream("stdout", details["stdout"])

    if map_size(diagnostics) == 0,
      do: projected,
      else: Map.put(projected, "diagnostics", diagnostics)
  end

  defp maybe_put_diagnostics(projected, _details), do: projected

  defp maybe_put_stream(diagnostics, key, %{"value" => value} = stream)
       when is_binary(value) do
    compact = %{
      "encoding" => stream["encoding"],
      "value" => String.slice(value, 0, @diagnostic_text_limit),
      "truncated" => String.length(value) > @diagnostic_text_limit
    }

    Map.put(diagnostics, key, compact)
  end

  defp maybe_put_stream(diagnostics, _key, _stream), do: diagnostics

  defp compact_repeated_operations(evidence) do
    {compacted, _signatures} =
      Enum.reduce(evidence, {[], MapSet.new()}, fn item, {items, signatures} ->
        case operation_signature(item) do
          nil ->
            {[item | items], signatures}

          signature ->
            if MapSet.member?(signatures, signature) do
              {items, signatures}
            else
              {[item | items], MapSet.put(signatures, signature)}
            end
        end
      end)

    Enum.reverse(compacted)
  end

  defp operation_signature(%{
         kind: kind,
         content: %{
           "request_kind" => request_kind,
           "target_id" => target_id,
           "access_method_id" => access_method_id,
           "capability" => capability,
           "operation" => operation,
           "selectors" => selectors,
           "parameters" => parameters
         }
       })
       when kind in ["observation", "operation_outcome"] and is_binary(request_kind) and
              is_binary(target_id) and is_binary(access_method_id) and is_binary(capability) and
              is_binary(operation) and is_map(selectors) and is_map(parameters) do
    {request_kind, target_id, access_method_id, capability, operation, selectors, parameters}
  end

  defp operation_signature(_evidence), do: nil

  defp evidence_target_id(
         %{content: %{"target_id" => target_id}},
         allowed_target_ids
       )
       when is_binary(target_id) do
    if target_id in allowed_target_ids, do: target_id
  end

  defp evidence_target_id(_evidence, _allowed_target_ids), do: nil

  defp add_items(request, field, items) do
    Enum.reduce(items, request, fn item, current ->
      case try_update(current, fn value -> Map.update!(value, field, &(&1 ++ [item])) end) do
        {:ok, updated} -> updated
        :full -> current
      end
    end)
  end

  defp try_update(request, update) do
    candidate = request |> update.() |> normalize_disclosure()
    limits = AI.resolver_disclosure_limits()

    if length(AI.resolver_disclosure_items(candidate)) <= limits.max_items and
         AI.resolver_disclosure_size(candidate) <= limits.max_bytes and
         length(candidate.disclosure.allowed_target_ids) <= limits.max_items and
         length(candidate.disclosure.allowed_evidence_kinds) <= limits.max_items do
      {:ok, candidate}
    else
      :full
    end
  end

  defp normalize_disclosure(request) do
    target_ids =
      selected_target_ids(request)
      |> Kernel.++(Enum.map(request.target_candidates, & &1.id))
      |> Kernel.++(
        Enum.flat_map(request.target_relations, fn relation ->
          [relation.source_target.id, relation.destination_target.id]
        end)
      )
      |> Kernel.++(Enum.map(request.evidence, & &1.target_id))
      |> Kernel.++(Enum.map(request.historical_evidence, & &1.target_id))
      |> Kernel.++(Enum.map(request.observation_tools ++ request.proposal_tools, & &1.target_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    evidence_kinds =
      (Enum.map(request.evidence ++ request.historical_evidence, & &1.kind) ++
         Enum.map(request.observation_results, & &1.kind))
      |> Enum.uniq()

    %{
      request
      | disclosure: %{
          request.disclosure
          | allowed_target_ids: target_ids,
            allowed_evidence_kinds: evidence_kinds
        }
    }
  end

  defp selected_target_ids(%AI.ResolverRequest{selected_target_id: nil}), do: []

  defp selected_target_ids(%AI.ResolverRequest{selected_target_id: id}), do: [id]
  defp selected_target_ids(nil), do: []
  defp selected_target_ids(target), do: [target.id]
end
