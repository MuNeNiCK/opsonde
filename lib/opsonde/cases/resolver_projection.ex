defmodule Opsonde.Cases.ResolverProjection do
  @moduledoc false

  alias Opsonde.{Cases, Providers, Targets}
  alias Opsonde.Providers.AI

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
         {:ok, target} <- selected_target(incident),
         {:ok, tools} <- tools(target, run, invocation),
         request <- request(selection, incident, run, turn, evidence, target, tools),
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

  defp tools(nil, _run, _invocation), do: {:ok, {[], []}}

  defp tools(target, run, invocation) do
    if remaining(run.max_target_requests, run.target_request_count) == 0 and
         remaining(run.max_effects, run.effect_count) == 0 do
      {:ok, {[], []}}
    else
      with {:ok, methods} <-
             Targets.available_access_methods_for_target(target.id, authorize?: false),
           {:ok, capabilities} <- capabilities(methods, invocation) do
        {:ok, build_tools(target, run, methods, capabilities)}
      end
    end
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

  defp build_tools(target, run, methods, capabilities) do
    observation? = remaining(run.max_target_requests, run.target_request_count) > 0
    proposal? = remaining(run.max_effects, run.effect_count) > 0

    Enum.reduce(methods, {[], []}, fn method, {observations, proposals} ->
      vocabulary = Map.fetch!(capabilities, {method.provider_id, method.provider_revision})

      method_observations =
        if observation?,
          do: operation_tools(:observation, target, method, vocabulary.observations),
          else: []

      method_proposals =
        if proposal?,
          do: operation_tools(:proposal, target, method, vocabulary.effects),
          else: []

      {observations ++ method_observations, proposals ++ method_proposals}
    end)
  end

  defp operation_tools(kind, target, method, operations) do
    operations
    |> Enum.filter(&(&1.capability in method.capabilities))
    |> Enum.sort_by(&{&1.capability, &1.operation})
    |> Enum.map(fn operation ->
      fields = %{
        id: tool_id(kind, method, operation),
        target_id: target.id,
        target_revision: target.revision,
        access_method_id: method.id,
        access_method_revision: method.revision,
        capability: operation.capability,
        operation: operation.operation,
        description: operation.description,
        input_schema: operation.input_schema
      }

      case kind do
        :observation -> struct!(AI.ObservationTool, fields)
        :proposal -> struct!(AI.ProposalTool, fields)
      end
    end)
  end

  defp tool_id(kind, method, operation) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {kind, method.id, method.revision, operation.capability, operation.operation},
          [:deterministic]
        )
      )
      |> Base.url_encode64(padding: false)

    "#{kind}:#{digest}"
  end

  defp request(selection, incident, run, turn, evidence, target, {observations, proposals}) do
    limits = AI.resolver_disclosure_limits()

    base = %AI.ResolverRequest{
      provider_revision: selection.provider_revision,
      session_id: "resolver:#{run.id}",
      case_id: incident.id,
      turn: turn.ordinal,
      objective: objective(incident, turn),
      alert_state: incident.alert_state,
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
      observation_results: [],
      target_relations: [],
      observation_tools: [],
      proposal_tools: []
    }

    base
    |> add_candidate_group(evidence)
    |> add_items(:observation_tools, observations)
    |> add_items(:proposal_tools, proposals)
    |> then(fn current ->
      add_items(
        current,
        :evidence,
        generic_evidence(evidence, current.disclosure.allowed_target_ids)
      )
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

        case try_update(request, fn current -> %{current | evidence: [compact]} end) do
          {:ok, with_evidence} ->
            Enum.reduce(candidates, with_evidence, fn candidate, current ->
              result =
                try_update(current, fn value ->
                  [head | rest] = value.evidence

                  updated = %{
                    head
                    | content: %{
                        head.content
                        | "candidate_ids" => head.content["candidate_ids"] ++ [candidate.id]
                      }
                  }

                  %{
                    value
                    | evidence: [updated | rest],
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

  defp generic_evidence(evidence, allowed_target_ids) do
    evidence
    |> Enum.reject(&candidate_evidence?/1)
    |> Enum.map(fn item ->
      %AI.Evidence{
        id: item.id,
        kind: item.kind,
        target_id: evidence_target_id(item, allowed_target_ids),
        content: item.content
      }
    end)
  end

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
