defmodule Opsonde.Cases.Case.Actions.DownstreamDecisionRoute do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    Approval,
    Budget,
    Case,
    CaseAdmissionLock,
    CaseEvent,
    CaseSymptom,
    ConditionContext,
    ConditionRecovery,
    Evidence,
    Proposal,
    RecoveryReviewFingerprint,
    ResolutionRun,
    Turn
  }

  alias Opsonde.Cases.Case.Actions.RecoveryCompletion

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source_turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false) do
      case resolved_replay(source_turn) do
        {:ok, %Case{}} = replayed ->
          replayed

        :continue ->
          Ash.transact([Case, ResolutionRun, Turn, Evidence, Proposal, Approval, CaseEvent], fn ->
            with :ok <- CaseAdmissionLock.acquire(),
                 {:ok, incident} <- lock_case(source_turn.case_id),
                 {:ok, run} <- lock_run(source_turn.resolution_run_id, incident.id),
                 {:ok, turn} <- lock_turn(source_turn.id, incident.id, run.id),
                 {:ok, current?} <- ConditionContext.current?(incident, turn.id),
                 true <- current? || {:error, "Resolver Condition snapshot changed"},
                 {:ok, intent} <- downstream_intent(turn),
                 :ok <- validate_intent(intent, turn, incident, run) do
              route(turn, intent, incident, run)
            end
          end)

        {:error, _error} = error ->
          error
      end
    end
  end

  defp route(turn, %{"type" => "recovery_conclusion"} = intent, incident, run) do
    with :ok <- ensure_running(incident, run),
         {:ok, review} <- recovery_review_event(turn) do
      case review do
        nil ->
          request_recovery_review(turn, intent, incident, run)

        %CaseEvent{data: %{"verdict" => "approved"}} = event ->
          complete_reviewed_recovery(turn, intent, incident, run, event)

        %CaseEvent{} ->
          incident
      end
    end
  end

  defp route(turn, intent, incident, run), do: route_other(turn, intent, incident, run)

  defp request_recovery_review(turn, intent, incident, run) do
    pending = %{"action" => "review_recovery", "turn_id" => turn.id}

    with :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, existing} <- existing_event(incident.id, review_request_key(turn)) do
      if existing do
        if incident.pending_intent == pending and
             existing.event_type == "recovery_review_requested" and
             existing.resolution_run_id == run.id and
             existing.data["result_digest"] == turn.result_digest do
          incident
        else
          {:error, "Recovery Review request was already used with different input"}
        end
      else
        case review_retry_gate(incident, intent) do
          :ok ->
            persist_recovery_review_request(turn, intent, incident, run, pending)

          {:blocked, reason} ->
            Cases.require_case_attention(
              incident.id,
              incident.revision,
              run.id,
              run.revision,
              "unchanged-recovery-review:#{turn.id}",
              reason,
              %{"action" => "retry_resolver"},
              "Collect new recovery evidence before asking for another review",
              authorize?: false
            )
            |> action_value()

          {:error, _error} = error ->
            error
        end
      end
    end
  end

  defp review_retry_gate(incident, intent) do
    with {:ok, fingerprint} <- RecoveryReviewFingerprint.current(incident, intent),
         {:ok, history} <- Cases.recovery_review_history(incident.id, authorize?: false) do
      cond do
        length(history) >= 501 ->
          {:blocked, "Recovery Review history exceeds the safe comparison limit"}

        Enum.any?(history, fn event ->
          event.data["verdict"] == "rejected" and
              event.data["review_fingerprint"] == fingerprint
        end) ->
          {:blocked, "Recovery Review rejected this unchanged evidence"}

        true ->
          :ok
      end
    end
  end

  defp persist_recovery_review_request(turn, intent, incident, run, pending) do
    with :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, updated} <-
           Cases.update_case_record(
             incident,
             incident.revision,
             %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "recovery_review_requested",
               idempotency_key: review_request_key(turn),
               data: %{
                 "source_turn_id" => turn.id,
                 "result_digest" => turn.result_digest,
                 "evidence_ids" => intent["evidence_ids"]
               }
             },
             authorize?: false
           ),
         {:ok, _job} <-
           %{"turn_id" => turn.id}
           |> Opsonde.Cases.RecoveryReviewWorker.new()
           |> Oban.insert() do
      updated
    end
  end

  defp complete_reviewed_recovery(turn, intent, incident, run, event) do
    expected = %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "evidence_ids" => intent["evidence_ids"],
      "condition_claims" => intent["condition_claims"],
      "case_symptom_claims" => intent["case_symptom_claims"]
    }

    with :ok <- available_pending_intent(incident.pending_intent, %{}, turn),
         true <-
           (event.event_type == "recovery_review_decided" and
              event.resolution_run_id == run.id and event.data["verdict"] == "approved" and
              Map.take(event.data, Map.keys(expected)) == expected and
              is_binary(event.data["ai_invocation_id"]) and
              is_binary(event.data["provider_id"]) and
              is_binary(event.data["invocation_key"])) ||
             {:error, "Recovery Review did not approve this exact conclusion"},
         {:ok, invocation} <-
           Cases.ai_invocation_by_idempotency(event.data["invocation_key"],
             authorize?: false,
             not_found_error?: false
           ),
         true <-
           ((invocation && invocation.id == event.data["ai_invocation_id"]) and
              invocation.turn_id == turn.id and invocation.case_id == incident.id and
              invocation.resolution_run_id == run.id and invocation.role == :reviewer and
              invocation.status == :completed and
              invocation.provider_id == event.data["provider_id"] and
              invocation.assignment_id == event.data["assignment_id"] and
              invocation.result_digest ==
                Opsonde.Cases.AIInvocation.request_digest(event.data)) ||
             {:error, "Recovery Reviewer invocation is unavailable"},
         {:ok, resolved} <-
           RecoveryCompletion.complete(
             incident,
             run,
             route_key(turn),
             Map.put(resolved_event_data(turn, intent), "recovery_review_event_id", event.id)
           ) do
      resolved
    end
  end

  defp recovery_review_event(turn) do
    existing_event(turn.case_id, review_result_key(turn))
  end

  defp route_other(turn, %{"type" => "handoff"} = intent, incident, run) do
    pending = pending_intent("provide_human_input", turn)
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay_handoff(incident, event, turn, intent, pending)
      else
        with :ok <- ensure_running(incident, run),
             :ok <- available_pending_intent(incident.pending_intent, pending, turn) do
          Cases.require_case_attention(
            incident.id,
            incident.revision,
            run.id,
            run.revision,
            key,
            intent["reason"],
            pending,
            intent["required_input"],
            authorize?: false
          )
          |> action_value()
        end
      end
    end
  end

  defp route_other(turn, %{"type" => "proposal"} = intent, incident, run) do
    with {:ok, proposal} <- Cases.materialize_proposal(turn.id, authorize?: false),
         pending <- %{
           "action" => "route_proposal",
           "proposal_id" => proposal.id,
           "source_turn_id" => turn.id
         },
         %Case{} <- persist_or_replay(turn, intent, incident, run, pending),
         {:ok, _proposal} <-
           Cases.route_proposal_authority(proposal.id, authorize?: false),
         {:ok, routed} <- Cases.get_case(incident.id, authorize?: false) do
      routed
    end
  end

  defp route_other(turn, intent, incident, run) do
    pending = pending_intent("evaluate_recovery", turn)
    persist_or_replay(turn, intent, incident, run, pending)
  end

  defp persist_or_replay(turn, intent, incident, run, pending) do
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay(incident, event, turn, intent, pending)
      else
        persist(incident, run, turn, intent, pending, key)
      end
    end
  end

  defp persist(incident, run, turn, intent, pending, key) do
    with :ok <- ensure_running(incident, run),
         :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, updated} <-
           Cases.update_case_record(
             incident,
             incident.revision,
             %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "resolver_decision_routed",
               idempotency_key: key,
               data: event_data(turn, intent, pending)
             },
             authorize?: false
           ) do
      updated
    end
  end

  defp replay(incident, event, turn, intent, pending) do
    if event.event_type == "resolver_decision_routed" and
         event.resolution_run_id == turn.resolution_run_id and
         event.data == event_data(turn, intent, pending) do
      incident
    else
      {:error, "Resolver decision route was already used with different input"}
    end
  end

  defp replay_handoff(incident, event, turn, intent, pending) do
    expected = %{
      "reason" => intent["reason"],
      "pending_intent" => pending,
      "required_human_input" => intent["required_input"]
    }

    if event.event_type == "case_needs_attention" and
         event.resolution_run_id == turn.resolution_run_id and event.data == expected do
      incident
    else
      {:error, "Resolver decision route was already used with different input"}
    end
  end

  defp downstream_intent(%{
         status: :completed,
         result_digest: digest,
         result: %{"outcome" => "decision", "intent" => %{"type" => type} = intent}
       })
       when is_binary(digest) and type in ["proposal", "recovery_conclusion", "handoff"],
       do: {:ok, intent}

  defp downstream_intent(_turn),
    do: {:error, "Completed Turn does not contain a downstream Resolver decision"}

  defp validate_intent(%{"type" => "proposal"}, _turn, _incident, _run), do: :ok

  defp validate_intent(
         %{
           "type" => "recovery_conclusion",
           "reason" => reason,
           "evidence_ids" => evidence_ids,
           "condition_claims" => claims,
           "case_symptom_claims" => symptom_claims
         },
         turn,
         incident,
         run
       )
       when is_binary(reason) and is_list(evidence_ids) do
    with :ok <- valid_reason(reason),
         :ok <- valid_recovery_state(incident),
         :ok <- valid_case_evidence(evidence_ids, incident.id),
         :ok <- valid_fresh_verification(evidence_ids, claims, turn, incident, run),
         :ok <- valid_case_symptom_claims(symptom_claims, evidence_ids, incident, run) do
      :ok
    end
  end

  defp validate_intent(
         %{
           "type" => "handoff",
           "reason" => reason,
           "required_input" => required_input
         },
         _turn,
         _incident,
         _run
       )
       when is_binary(reason) and is_binary(required_input) and byte_size(required_input) > 0 and
              byte_size(required_input) <= 1_000,
       do: valid_reason(reason)

  defp validate_intent(_intent, _turn, _incident, _run),
    do: {:error, "Downstream Resolver decision is malformed"}

  defp valid_case_symptom_claims([], _evidence_ids, %{trigger_kind: :signal}, _run), do: :ok

  defp valid_case_symptom_claims(claims, evidence_ids, incident, run)
       when incident.trigger_kind in [:manual, :audit] and is_list(claims) do
    cited =
      claims
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["evidence_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, evidence} <- fetch_claim_evidence(cited, incident.id),
         true <-
           CaseSymptom.valid_claims?(
             claims,
             CaseSymptom.current(incident),
             evidence_ids,
             evidence
           ) || {:error, "Recovery conclusion lacks a current Case symptom claim"},
         :ok <- verify_claim_evidence(evidence, incident, run) do
      :ok
    end
  end

  defp valid_case_symptom_claims(_claims, _evidence_ids, _incident, _run),
    do: {:error, "Recovery conclusion has unexpected Case symptom claims"}

  defp fetch_claim_evidence(ids, case_id) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, %{case_id: ^case_id} = item} -> {:cont, {:ok, [item | items]}}
        _unavailable -> {:halt, {:error, "Recovery conclusion cites unavailable Case Evidence"}}
      end
    end)
  end

  defp verify_claim_evidence(items, incident, run) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      result =
        case item.kind do
          "observation" ->
            valid_fresh_observation(item, incident, run)

          "target_verification" ->
            with :ok <- valid_continuity_evidence(item, incident),
                 :ok <- validate_target_continuity_verification([item.id], incident) do
              :ok
            end

          _other ->
            {:error, "Recovery conclusion cites unsupported Case Evidence"}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_reason(reason) do
    if Opsonde.Providers.AI.valid_resolver_reason?(reason),
      do: :ok,
      else: {:error, "Downstream Resolver decision is malformed"}
  end

  defp valid_recovery_state(%{trigger_kind: :signal}), do: :ok

  defp valid_recovery_state(%{trigger_kind: kind}) when kind in [:manual, :audit],
    do: :ok

  defp valid_recovery_state(_incident),
    do: {:error, "Monitoring source has not confirmed recovery"}

  defp valid_fresh_verification(
         evidence_ids,
         claims,
         _turn,
         %{trigger_kind: :signal} = incident,
         _run
       ) do
    with {:ok, assessments} <- ConditionRecovery.assess_current(incident),
         true <-
           ConditionRecovery.ready_for_review?(assessments) ||
             {:error, "Signal Conditions require current observations and Resolver assessment"},
         true <- is_list(claims) || {:error, "Recovery conclusion lacks Condition claims"},
         expected <- Map.new(assessments, &{&1.condition_id, &1}),
         true <-
           length(claims) == map_size(expected) ||
             {:error, "Recovery conclusion omits a Condition"},
         true <-
           Enum.all?(claims, fn claim ->
             is_map(claim) and
               case Map.get(expected, claim["condition_id"]) do
                 nil ->
                   false

                 assessment ->
                   assessment.revision == claim["revision"] and
                     claim["evidence_id"] in assessment.evidence_ids and
                     claim["evidence_id"] in evidence_ids and
                     Opsonde.Providers.AI.valid_resolver_reason?(claim["reason"])
               end
           end) || {:error, "Recovery conclusion cites a changed Condition"},
         true <-
           MapSet.new(Enum.map(claims, & &1["condition_id"])) == MapSet.new(Map.keys(expected)) ||
             {:error, "Recovery conclusion contains duplicate Condition claims"} do
      :ok
    end
  end

  defp valid_fresh_verification(evidence_ids, [], turn, incident, run) do
    evidence_id = turn.intent["verification_evidence_id"]
    operation_id = turn.intent["operation_id"]

    if is_binary(evidence_id) and is_binary(operation_id) do
      validate_current_verification(evidence_ids, evidence_id, operation_id, incident, run)
    else
      validate_continuity_verification(evidence_ids, incident, run)
    end
  end

  defp valid_fresh_verification(_evidence_ids, _claims, _turn, _incident, _run),
    do: {:error, "Recovery conclusion has unexpected Condition claims"}

  defp validate_current_verification(evidence_ids, evidence_id, operation_id, incident, run) do
    if evidence_id in evidence_ids do
      case Cases.get_evidence(evidence_id, authorize?: false) do
        {:ok,
         %{
           case_id: case_id,
           resolution_run_id: run_id,
           kind: "target_verification",
           source: "verification",
           content: %{"status" => "verified", "operation_id" => ^operation_id}
         }}
        when case_id == incident.id and run_id == run.id ->
          :ok

        _unavailable ->
          {:error, "Recovery conclusion lacks the current verified Target Evidence"}
      end
    else
      {:error, "Recovery conclusion omits the current verification Evidence"}
    end
  end

  defp validate_continuity_verification(evidence_ids, incident, run) do
    case validate_target_continuity_verification(evidence_ids, incident) do
      :ok -> :ok
      {:error, _error} -> validate_fresh_observation(evidence_ids, incident, run)
    end
  end

  defp validate_target_continuity_verification(evidence_ids, incident) do
    with {:ok, candidates} <-
           Cases.target_continuity_evidence(incident.id, authorize?: false),
         %{} = latest <-
           Enum.find(candidates, &(&1.content["target_id"] == incident.selected_target_id)),
         true <-
           latest.id in evidence_ids ||
             {:error, "Recovery conclusion omits the latest verified Target Evidence"},
         :ok <- valid_continuity_evidence(latest, incident) do
      :ok
    else
      nil -> {:error, "Recovery conclusion lacks verified Target Evidence"}
      {:error, _error} = error -> error
    end
  end

  defp validate_fresh_observation(evidence_ids, incident, run) do
    Enum.reduce_while(
      evidence_ids,
      {:error, "Recovery conclusion lacks fresh Target Evidence"},
      fn
        evidence_id, _result ->
          case Cases.get_evidence(evidence_id, authorize?: false) do
            {:ok, evidence} ->
              case valid_fresh_observation(evidence, incident, run) do
                :ok -> {:halt, :ok}
                {:error, _error} = error -> {:cont, error}
              end

            {:error, _error} ->
              {:cont, {:error, "Recovery conclusion cites unavailable Target Evidence"}}
          end
      end
    )
  end

  defp valid_fresh_observation(
         %{
           case_id: case_id,
           resolution_run_id: run_id,
           kind: "observation",
           source: "operation",
           source_ref: operation_id,
           observed_at: observed_at,
           content: %{
             "status" => "applied",
             "category" => "target_observed",
             "target_id" => target_id,
             "facts" => facts
           }
         },
         %{
           id: case_id,
           selected_target_id: target_id,
           selected_target_revision: target_revision
         } = incident,
         %{id: run_id}
       )
       when is_map(facts) and map_size(facts) > 0 do
    with {:ok, baseline} <- ConditionRecovery.baseline_for_case(incident),
         true <- DateTime.compare(observed_at, baseline) in [:eq, :gt],
         {:ok,
          %{
            case_id: ^case_id,
            resolution_run_id: ^run_id,
            target_id: ^target_id,
            target_revision: ^target_revision,
            request_kind: :observation,
            status: :applied,
            dispatch_started_at: %DateTime{} = dispatch_started_at
          }} <- Cases.get_operation(operation_id, authorize?: false) do
      if DateTime.compare(dispatch_started_at, baseline) in [:eq, :gt],
        do: :ok,
        else: {:error, "Recovery conclusion cites an earlier Target observation"}
    else
      _stale -> {:error, "Recovery conclusion cites stale Target observation"}
    end
  end

  defp valid_fresh_observation(_evidence, _incident, _run),
    do: {:error, "Recovery conclusion lacks fresh Target Evidence"}

  defp valid_continuity_evidence(
         %{
           case_id: case_id,
           kind: "target_verification",
           source: "verification",
           content: %{
             "status" => "verified",
             "operation_id" => operation_id,
             "target_id" => target_id
           }
         },
         %{id: case_id, selected_target_id: target_id, selected_target_revision: target_revision}
       ) do
    case Cases.get_operation(operation_id, authorize?: false) do
      {:ok,
       %{
         case_id: ^case_id,
         target_id: ^target_id,
         target_revision: ^target_revision,
         status: :applied
       }} ->
        :ok

      _unavailable ->
        {:error, "Recovery conclusion cites stale Target verification"}
    end
  end

  defp valid_continuity_evidence(_evidence, _incident),
    do: {:error, "Recovery conclusion lacks verified Target Evidence"}

  defp valid_case_evidence(ids, case_id) do
    with :ok <- unique_ids(ids) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Cases.get_evidence(id, authorize?: false) do
          {:ok, %{case_id: ^case_id}} -> {:cont, :ok}
          _unavailable -> {:halt, {:error, "Resolver decision cites unavailable Evidence"}}
        end
      end)
    end
  end

  defp unique_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) and
         length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, "Resolver decision Evidence identities are invalid"}
    end
  end

  defp unique_ids(_ids), do: {:error, "Resolver decision Evidence identities are invalid"}

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp lock_turn(id, case_id, run_id) do
    Turn
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Resolver Turn is unavailable")
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp ensure_running(%{status: :running, cancel_requested: false}, %{status: :running}), do: :ok

  defp ensure_running(%{cancel_requested: true}, _run),
    do: {:error, "Case cancellation was requested"}

  defp ensure_running(_incident, _run), do: {:error, "Case resolution is not running"}

  defp available_pending_intent(current, _pending, _turn) when map_size(current) == 0, do: :ok
  defp available_pending_intent(pending, pending, _turn), do: :ok

  defp available_pending_intent(%{"action" => "resolve_turn", "turn_id" => id}, _pending, %{
         id: id
       }),
       do: :ok

  defp available_pending_intent(
         %{"action" => "review_recovery", "turn_id" => id},
         _pending,
         %{id: id}
       ),
       do: :ok

  defp available_pending_intent(_current, _pending, _turn),
    do: {:error, "Case already has another pending decision"}

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp event_data(turn, intent, pending) do
    %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "intent_type" => intent["type"],
      "pending_intent" => pending
    }
  end

  defp resolved_event_data(turn, intent) do
    %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "intent_type" => intent["type"],
      "reason" => intent["reason"],
      "evidence_ids" => intent["evidence_ids"]
    }
  end

  defp resolved_replay(source_turn) do
    with {:ok, %{"type" => "recovery_conclusion"} = intent} <- downstream_intent(source_turn),
         {:ok, event} <- existing_event(source_turn.case_id, route_key(source_turn)) do
      case event do
        %CaseEvent{event_type: "case_resolved", data: data} ->
          if Map.drop(data, ["recovery_review_event_id"]) ==
               resolved_event_data(source_turn, intent) and
               is_binary(data["recovery_review_event_id"]),
             do: Cases.get_case(source_turn.case_id, authorize?: false),
             else: {:error, "Recovery conclusion was already resolved with different input"}

        _other ->
          :continue
      end
    else
      {:ok, _other_intent} -> :continue
      {:error, "Completed Turn does not contain a downstream Resolver decision"} -> :continue
      {:error, _error} = error -> error
    end
  end

  defp pending_intent(action, turn),
    do: %{"action" => action, "source_turn_id" => turn.id}

  defp route_key(turn), do: Budget.key("resolver-route:downstream", turn.id)

  defp review_request_key(turn), do: Budget.key("recovery-review:requested", turn.id)
  defp review_result_key(turn), do: Budget.key("recovery-review:result", turn.id)

  defp action_value({:ok, value}), do: value
  defp action_value({:error, _error} = error), do: error
end
