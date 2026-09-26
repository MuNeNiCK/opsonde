defmodule Opsonde.Cases.ResolverProjection do
  @moduledoc false

  alias Opsonde.{Cases, Providers, Targets}
  alias Opsonde.Providers.AI
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.BMC.OperationKey

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
         {:ok, source_context} <- source_context(incident, evidence),
         {:ok, target} <- selected_target(incident),
         {:ok, continuity} <- target_continuity(incident, target, source_context),
         {:ok, relations} <- relations(target, incident, run, turn),
         {:ok, tools} <- tools(target, run, invocation),
         request <-
           request(selection, incident, run, turn, continuity, target, relations, tools),
         :ok <- AI.Validator.validate_request(:resolve, request) do
      {:ok, request}
    end
  end

  def build(_turn_id, _selection, _invocation),
    do: {:error, "Resolver AI selection is invalid"}

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

  defp relations(nil, _incident, _run, _turn), do: {:ok, []}

  defp relations(
         _target,
         _incident,
         %{max_related_targets: maximum, related_target_count: count},
         _turn
       )
       when count >= maximum,
       do: {:ok, []}

  defp relations(target, _incident, _run, turn) do
    with {:ok, relationships} <-
           Targets.adjacent_relationships_for_traversal(target.id, authorize?: false) do
      relationships
      |> Enum.reject(&immediate_reverse?(&1, turn))
      |> Enum.reduce([], fn relationship, projected ->
        case relation(relationship, target) do
          {:ok, value} -> [value | projected]
          :skip -> projected
        end
      end)
      |> Enum.reverse()
      |> then(&{:ok, &1})
    end
  end

  defp immediate_reverse?(relationship, %{intent: %{"source" => "target_relationship"} = intent}) do
    relationship.id == intent["relationship_id"]
  end

  defp immediate_reverse?(_relationship, _turn), do: false

  defp relation(relationship, target) do
    next_target_id =
      if relationship.source_target_id == target.id,
        do: relationship.destination_target_id,
        else: relationship.source_target_id

    case Targets.get_target(next_target_id, authorize?: false) do
      {:ok, %{active: true} = next_target} ->
        current = target_candidate(target)
        adjacent = target_candidate(next_target)

        {source, destination} =
          if relationship.source_target_id == target.id,
            do: {current, adjacent},
            else: {adjacent, current}

        {:ok,
         %AI.TargetRelation{
           id: relationship.id,
           revision: relationship.revision,
           source_target: source,
           destination_target: destination,
           kind: relationship.kind,
           attributes: relationship.facts
         }}

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

  defp tools(nil, _run, _invocation), do: {:ok, {[], []}}

  defp tools(target, run, invocation) do
    if remaining(run.max_target_requests, run.target_request_count) == 0 and
         remaining(run.max_effects, run.effect_count) == 0 do
      {:ok, {[], []}}
    else
      with {:ok, methods} <-
             Targets.available_access_methods_for_target(target.id, authorize?: false),
           {:ok, capabilities} <- capabilities(methods, invocation),
           {:ok, definitions} <- bmc_definitions(methods) do
        {:ok, build_tools(target, run, methods, capabilities, definitions)}
      end
    end
  end

  defp bmc_definitions(methods) do
    Enum.reduce_while(methods, {:ok, %{}}, fn method, {:ok, loaded} ->
      if method.method in ["redfish", "ipmi"] do
        case Targets.available_bmc_operations_for_method(method.id, authorize?: false) do
          {:ok, definitions} -> {:cont, {:ok, Map.put(loaded, method.id, definitions)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, loaded}}
      end
    end)
  end

  defp capabilities(methods, invocation) do
    methods
    |> Enum.uniq_by(&{&1.provider_id, &1.provider_revision})
    |> Enum.reduce_while({:ok, %{}}, fn method, {:ok, loaded} ->
      key = {method.provider_id, method.provider_revision}

      case Providers.target_capabilities(
             method.provider_id,
             method.provider_revision,
             invocation,
             authorize?: false
           ) do
        {:ok, value} -> {:cont, {:ok, Map.put(loaded, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp build_tools(target, run, methods, capabilities, definitions) do
    observation? = remaining(run.max_target_requests, run.target_request_count) > 0
    proposal? = remaining(run.max_effects, run.effect_count) > 0

    Enum.reduce(methods, {[], []}, fn method, {observations, proposals} ->
      vocabulary = Map.fetch!(capabilities, {method.provider_id, method.provider_revision})

      advertised =
        vocabulary.observations
        |> Kernel.++(vocabulary.effects)
        |> Enum.map(& &1.capability)
        |> MapSet.new()

      bmc_operations =
        definitions
        |> Map.get(method.id, [])
        |> Enum.filter(&MapSet.member?(advertised, OperationKey.capability(&1.request_kind)))

      available_observations =
        vocabulary.observations ++
          Enum.flat_map(bmc_operations, fn definition ->
            if definition.request_kind == :observation,
              do: [bmc_operation_tool(definition)],
              else: []
          end)

      effects =
        vocabulary.effects ++
          Enum.flat_map(bmc_operations, fn definition ->
            if definition.request_kind == :effect,
              do: [bmc_operation_tool(definition)],
              else: []
          end)

      method_observations =
        if observation?,
          do: operation_tools(:observation, target, method, available_observations),
          else: []

      observation_requests =
        if observation?,
          do: operation_tools(:request_observation, target, method, available_observations),
          else: []

      effect_requests =
        if proposal?,
          do: operation_tools(:request_effect, target, method, effects),
          else: []

      {observations ++ method_observations, proposals ++ observation_requests ++ effect_requests}
    end)
  end

  defp bmc_operation_tool(definition) do
    %ProviderTarget.Operation{
      capability: OperationKey.capability(definition.request_kind),
      operation: OperationKey.format(definition),
      description: definition.description,
      input_schema: definition.input_schema,
      output_schema: definition.output_schema,
      verification_schema: definition.verification_schema
    }
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
        description: operation.description,
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
         evidence,
         target,
         relations,
         {observations, proposals}
       ) do
    limits = AI.resolver_disclosure_limits()

    base = %AI.ResolverRequest{
      provider_revision: selection.provider_revision,
      session_id: "resolver:#{run.id}",
      case_id: incident.id,
      turn: turn.ordinal,
      objective: objective(incident, turn),
      alert_state: incident.alert_state,
      report_language: incident.report_language,
      disclosure: %AI.Disclosure{
        allowed_target_ids: selected_target_ids(target),
        allowed_evidence_kinds: [],
        max_items: limits.max_items,
        max_bytes: limits.max_bytes
      },
      budget: budget(run, turn),
      evidence: [],
      target_candidates: [],
      selected_target_id: target && target.id,
      selected_target_revision: target && target.revision,
      retry_context: retry_context(turn),
      observation_results: [],
      target_relations: [],
      observation_tools: [],
      proposal_tools: []
    }

    {source_evidence, other_evidence} =
      Enum.split_with(evidence, &(&1.kind == "signal_event"))

    base
    |> add_items(
      :evidence,
      generic_evidence(source_evidence, base.disclosure.allowed_target_ids, incident, run)
    )
    |> add_candidate_group(other_evidence)
    |> add_items(:target_relations, relations)
    |> add_items(:observation_tools, observations)
    |> add_items(:proposal_tools, proposals)
    |> then(fn current ->
      add_items(
        current,
        :evidence,
        generic_evidence(other_evidence, current.disclosure.allowed_target_ids, incident, run)
      )
    end)
    |> then(fn current ->
      %{current | proposal_tools: AI.available_proposal_tools(current)}
    end)
    |> normalize_disclosure()
  end

  defp objective(incident, turn) do
    value = %{
      "case_title" => incident.title,
      "initial_context" => incident.initial_context,
      "turn_intent" => turn.intent
    }

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

  defp generic_evidence(evidence, allowed_target_ids, incident, run) do
    evidence
    |> Enum.reject(&candidate_evidence?/1)
    |> compact_repeated_operations()
    |> Enum.map(fn item ->
      %AI.Evidence{
        id: item.id,
        kind: item.kind,
        target_id: evidence_target_id(item, allowed_target_ids),
        content: recovery_evidence_content(item, incident, run)
      }
    end)
  end

  defp recovery_evidence_content(
         %{
           kind: "observation",
           observed_at: observed_at,
           content: %{
             "status" => "applied",
             "category" => "target_observed",
             "target_id" => target_id,
             "facts" => facts
           }
         } = evidence,
         %{
           selected_target_id: target_id,
           source_recovered_at: %DateTime{} = recovered_at
         },
         %{id: run_id}
       )
       when is_map(facts) and map_size(facts) > 0 do
    eligible? =
      evidence.resolution_run_id == run_id and
        DateTime.compare(observed_at, recovered_at) in [:eq, :gt]

    evidence
    |> projected_evidence_content()
    |> Map.put("recovery_eligible", eligible?)
  end

  defp recovery_evidence_content(evidence, _incident, _run),
    do: projected_evidence_content(evidence)

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
      |> Kernel.++(Enum.map(request.observation_tools ++ request.proposal_tools, & &1.target_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    evidence_kinds =
      (Enum.map(request.evidence, & &1.kind) ++
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
