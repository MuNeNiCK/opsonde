defmodule Opsonde.Cases.Case.Actions.ObservationRoute do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Accounts, Cases, Targets}
  alias Opsonde.Cases.{Budget, Case, CaseEvent, Evidence, ResolutionRun, Turn}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.{PolicyError, PolicyRequest}

  @max_content_bytes 65_536

  @impl true
  def run(input, _opts, _context) do
    turn_id = input.arguments.turn_id

    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, intent} <- observation_intent(turn),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
         {:ok, actor} <- current_actor(incident),
         {:ok, evidence} <- existing_evidence(incident.id, turn.id) do
      if evidence do
        persist_and_continue(turn, evidence_spec(evidence), incident, run)
      else
        observe(turn, intent, incident, run, actor, input.arguments.invocation)
      end
    end
  end

  defp observe(turn, intent, incident, run, actor, invocation) do
    request = request(turn, intent, incident)

    case Targets.clear_target_request(request, actor: actor) do
      {:ok, clearance} ->
        case exact_provider(clearance, intent) do
          :ok ->
            with {:ok, charged} <- charge(turn, incident, run) do
              if charged.status == :exhausted do
                {:ok, charged}
              else
                dispatch(turn, intent, charged.case, charged.run, actor, clearance, invocation)
              end
            end

          {:error, error} ->
            persist_and_continue(
              turn,
              error_spec("target_policy", error, intent),
              incident,
              run
            )
        end

      {:error, error} ->
        persist_and_continue(
          turn,
          error_spec("target_policy", error, intent),
          incident,
          run
        )
    end
  end

  defp dispatch(turn, intent, incident, run, actor, clearance, supplied_invocation) do
    invocation = invocation(incident.id, supplied_invocation)

    case Targets.dispatch_target_observation(clearance, invocation, actor: actor) do
      {:ok, %ProviderTarget.Observation{} = observation} ->
        persist_and_continue(turn, observation_spec(observation, intent), incident, run)

      {:error, error} ->
        persist_and_continue(
          turn,
          error_spec("target_provider", error, intent),
          incident,
          run
        )
    end
  end

  defp persist_and_continue(turn, spec, incident, run) do
    Ash.transact([Case, ResolutionRun, Turn, Evidence, CaseEvent], fn ->
      with {:ok, evidence} <- append_evidence(turn, spec),
           {:ok, next} <-
             Cases.start_turn(
               incident.id,
               run.id,
               route_key(turn, "next-turn"),
               %{
                 "objective" => "Continue resolution with the accepted observation",
                 "source" => "observation",
                 "source_turn_id" => turn.id,
                 "evidence_id" => evidence.id
               },
               %{"action" => "continue_resolution", "source_turn_id" => turn.id},
               "Review Resolver limits or continue the Case manually",
               authorize?: false
             ) do
        next
      end
    end)
  end

  defp append_evidence(turn, spec) do
    Cases.append_evidence(
      turn.case_id,
      turn.resolution_run_id,
      turn.id,
      evidence_key(turn.id),
      spec.kind,
      spec.source,
      turn.id,
      spec.content,
      spec.observed_at,
      authorize?: false
    )
  end

  defp charge(turn, incident, run) do
    Cases.charge_resolution_run(
      incident.id,
      run.id,
      :target_request,
      1,
      route_key(turn, "target-request"),
      %{"action" => "route_observation", "source_turn_id" => turn.id},
      "Review the Target request limit or continue the Case manually",
      authorize?: false
    )
  end

  defp request(turn, intent, incident) do
    tool = intent["tool"]

    %PolicyRequest{
      kind: :observation,
      authority_mode: incident.authority_mode,
      target_id: tool["target_id"],
      target_revision: tool["target_revision"],
      access_method_id: tool["access_method_id"],
      access_method_revision: tool["access_method_revision"],
      capability: tool["capability"],
      operation: tool["operation"],
      selectors: intent["selectors"],
      parameters: intent["parameters"],
      idempotency_key: route_key(turn, "observation"),
      max_attempts: 1
    }
  end

  defp observation_intent(%{
         status: :completed,
         result: %{
           "outcome" => "decision",
           "intent" =>
             %{
               "type" => "observation_choice",
               "tool_id" => tool_id,
               "tool" => %{
                 "id" => tool_id,
                 "target_id" => target_id,
                 "target_revision" => target_revision,
                 "access_method_id" => method_id,
                 "access_method_revision" => method_revision,
                 "provider_id" => provider_id,
                 "provider_revision" => provider_revision,
                 "capability" => capability,
                 "operation" => operation
               },
               "selectors" => selectors,
               "parameters" => parameters,
               "reason" => reason
             } = intent
         }
       })
       when is_binary(target_id) and is_integer(target_revision) and is_binary(method_id) and
              is_integer(method_revision) and is_binary(capability) and is_binary(operation) and
              is_binary(provider_id) and is_integer(provider_revision) and
              is_map(selectors) and is_map(parameters) and is_binary(reason),
       do: {:ok, intent}

  defp observation_intent(_turn),
    do: {:error, "Completed Turn does not contain an exact observation decision"}

  defp current_actor(%{current_owner_id: owner_id}) when is_binary(owner_id) do
    case Accounts.get_user(owner_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] -> {:ok, actor}
      _unavailable -> {:error, "Case owner cannot authorize Target observation"}
    end
  end

  defp current_actor(_incident), do: {:error, "Case has no Target observation owner"}

  defp exact_provider(clearance, intent) do
    tool = intent["tool"]

    if clearance.provider_id == tool["provider_id"] and
         clearance.provider_revision == tool["provider_revision"] do
      :ok
    else
      {:error,
       PolicyError.exception(
         category: :stale_context,
         message: "Target Provider changed after the Resolver decision"
       )}
    end
  end

  defp existing_evidence(case_id, turn_id) do
    Cases.evidence_by_idempotency(case_id, evidence_key(turn_id),
      authorize?: false,
      not_found_error?: false
    )
  end

  defp observation_spec(observation, intent) do
    content = %{
      "status" => "observed",
      "target_id" => intent["tool"]["target_id"],
      "tool_id" => intent["tool_id"],
      "facts" => observation.facts,
      "evidence" => observation.evidence
    }

    if encoded_size(content) <= @max_content_bytes do
      %{
        kind: "observation",
        source: "target_provider",
        content: content,
        observed_at: observation.observed_at
      }
    else
      %{
        kind: "observation_error",
        source: "target_provider",
        content:
          base_content(intent, "result_too_large", "Target observation result is too large"),
        observed_at: DateTime.utc_now()
      }
    end
  end

  defp error_spec(source, error, intent) do
    {category, message} = error_details(error)

    %{
      kind: "observation_error",
      source: source,
      content: base_content(intent, category, message),
      observed_at: DateTime.utc_now()
    }
  end

  defp evidence_spec(evidence) do
    %{
      kind: evidence.kind,
      source: evidence.source,
      content: evidence.content,
      observed_at: evidence.observed_at
    }
  end

  defp base_content(intent, category, message) do
    %{
      "status" => "failed",
      "category" => category,
      "message" => String.slice(message, 0, 1_000),
      "target_id" => intent["tool"]["target_id"],
      "tool_id" => intent["tool_id"]
    }
  end

  defp error_details(error) do
    case find_error(error) do
      %PolicyError{category: category, message: message} ->
        {to_string(category), message}

      %ProviderTarget.Error{category: category, message: message} ->
        {to_string(category), message}

      %{message: message} when is_binary(message) ->
        {"failed", message}

      _error ->
        {"failed", "Target observation failed"}
    end
  end

  defp find_error(%PolicyError{} = error), do: error
  defp find_error(%ProviderTarget.Error{} = error), do: error

  defp find_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_error/1)

  defp find_error(error), do: error

  defp invocation(case_id, supplied) do
    supplied_cancelled = Map.get(supplied, :cancelled?)

    Map.put(supplied, :cancelled?, fn ->
      cancelled?(supplied_cancelled) or case_cancelled?(case_id)
    end)
  end

  defp cancelled?(callback) when is_function(callback, 0), do: callback.()
  defp cancelled?(_callback), do: false

  defp case_cancelled?(case_id) do
    case Cases.get_case(case_id, authorize?: false) do
      {:ok, %{cancel_requested: true}} -> true
      {:ok, %{status: status}} when status != :running -> true
      {:ok, _incident} -> false
      {:error, _error} -> true
    end
  end

  defp encoded_size(content) do
    case Jason.encode(content) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  defp evidence_key(turn_id), do: route_key(%{id: turn_id}, "evidence")
  defp route_key(turn, kind), do: Budget.key("resolver-route:#{kind}", turn.id)
end
