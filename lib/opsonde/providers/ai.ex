defmodule Opsonde.Providers.AI do
  @moduledoc false

  @resolver_disclosure_limits %{max_items: 100, max_bytes: 65_536}
  @resolver_reason_codepoints 500

  def resolver_disclosure_limits, do: @resolver_disclosure_limits
  def resolver_reason_codepoints, do: @resolver_reason_codepoints

  def valid_resolver_reason?(reason) when is_binary(reason) and byte_size(reason) > 0 do
    case :unicode.characters_to_list(reason) do
      codepoints when is_list(codepoints) -> length(codepoints) <= @resolver_reason_codepoints
      _invalid -> false
    end
  end

  def valid_resolver_reason?(_reason), do: false

  defmodule Disclosure do
    @moduledoc false
    @enforce_keys [:allowed_target_ids, :allowed_evidence_kinds, :max_items, :max_bytes]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Budget do
    @moduledoc false

    @enforce_keys [
      :remaining_turns,
      :remaining_tokens,
      :remaining_target_requests,
      :remaining_effects,
      :remaining_related_targets
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Evidence do
    @moduledoc false
    @enforce_keys [:id, :kind, :content]
    defstruct @enforce_keys ++ [target_id: nil, observed_at_us: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Condition do
    @moduledoc false

    @enforce_keys [
      :id,
      :revision,
      :occurrence,
      :predicate,
      :subject_key,
      :subject_ref,
      :state,
      :target_id,
      :current_occurred_at_us
    ]

    defstruct @enforce_keys ++ [recovery_status: nil, recovery_evidence_id: nil]
    @type t :: %__MODULE__{}
  end

  def recovery_evidence_ids(request), do: request.recovery_evidence_ids

  def target_candidate_evidence_ids(request, target_id) do
    request.evidence
    |> Enum.filter(fn evidence ->
      (evidence.kind == "target_candidates" and is_map(evidence.content) and
         is_list(evidence.content["candidate_ids"]) and
         target_id in evidence.content["candidate_ids"]) or
        (evidence.kind == "signal_event" and is_map(evidence.content) and
           evidence.content["current"] == true and
           Enum.any?(request.conditions, fn condition ->
             condition.id == evidence.content["condition_id"] and
               condition.revision == evidence.content["condition_revision"] and
               condition.target_id == target_id
           end))
    end)
    |> Enum.map(& &1.id)
  end

  def available_proposal_tools(request) do
    Enum.filter(request.proposal_tools, &proposal_requirements_available?(&1, request))
  end

  def proposal_evidence_ids(request) do
    request.evidence
    |> Enum.filter(fn
      %Evidence{kind: "observation", target_id: target_id} ->
        target_id == request.selected_target_id

      _evidence ->
        false
    end)
    |> Enum.map(& &1.id)
    |> Kernel.++(
      request.observation_results
      |> Enum.filter(&(&1.kind == "observation" and &1.target_id == request.selected_target_id))
      |> Enum.map(& &1.id)
    )
    |> Enum.uniq()
  end

  def proposal_requirements_match?(tool, request, evidence_ids, parameters)
      when is_list(evidence_ids) and is_map(parameters) do
    Enum.all?(tool.evidence_requirements, fn requirement ->
      Enum.any?(matching_evidence(requirement, tool, request, evidence_ids), fn evidence ->
        parameters[requirement.parameter] == evidence.content["facts"][requirement.fact]
      end)
    end)
  end

  def proposal_requirements_match?(_tool, _request, _evidence_ids, _parameters), do: false

  def proposal_requirement_values(tool, request, requirement) do
    requirement
    |> matching_evidence(tool, request, nil)
    |> Enum.map(& &1.content["facts"][requirement.fact])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp proposal_requirements_available?(tool, request) do
    tool.request_kind == :observation or
      Enum.all?(tool.evidence_requirements, fn requirement ->
        matching_evidence(requirement, tool, request, nil) != []
      end)
  end

  defp matching_evidence(requirement, tool, request, evidence_ids) do
    observation_tool_ids =
      (request.observation_tools ++ request.proposal_tools)
      |> Enum.filter(fn observation ->
        Map.get(observation, :request_kind, :observation) == :observation and
          observation.target_id == tool.target_id and
          observation.access_method_id == tool.access_method_id and
          observation.provider_id == tool.provider_id and
          observation.operation == requirement.observation
      end)
      |> Enum.map(& &1.id)

    if observation_tool_ids != [] do
      Enum.filter(request.evidence, fn evidence ->
        evidence.kind == "observation" and evidence.target_id == tool.target_id and
          is_map(evidence.content) and
          (is_nil(evidence_ids) or evidence.id in evidence_ids) and
          evidence.content["tool_id"] in observation_tool_ids and
          is_map(evidence.content["facts"]) and
          Map.has_key?(evidence.content["facts"], requirement.fact) and
          not superseded_observation?(evidence, request, tool, requirement, observation_tool_ids)
      end)
    else
      []
    end
  end

  defp superseded_observation?(observation, request, tool, requirement, observation_tool_ids) do
    Enum.any?(request.evidence, fn newer ->
      newer.target_id == tool.target_id and
        newer.id != observation.id and
        later_evidence?(newer, observation) and
        is_map(newer.content) and
        newer.content["access_method_id"] == tool.access_method_id and
        is_map(newer.content["facts"]) and
        Map.has_key?(newer.content["facts"], requirement.fact) and
        ((newer.kind == "target_verification" and newer.content["status"] == "verified") or
           (newer.kind == "observation" and newer.content["tool_id"] in observation_tool_ids))
    end)
  end

  defp later_evidence?(%{observed_at_us: newer}, %{observed_at_us: older})
       when is_integer(newer) and is_integer(older),
       do: newer > older

  defp later_evidence?(_newer, _older), do: false

  defmodule TargetCandidate do
    @moduledoc false
    @enforce_keys [:id, :revision, :name, :kind, :platform, :facts]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetSearch do
    @moduledoc false
    @enforce_keys [:query, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetSelection do
    @moduledoc false
    @enforce_keys [:target_id, :target_revision, :evidence_ids, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ObservationResult do
    @moduledoc false
    @enforce_keys [:id, :tool_id, :target_id, :kind, :status, :content]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetRelation do
    @moduledoc false
    @enforce_keys [:id, :revision, :source_target, :destination_target, :kind]
    defstruct @enforce_keys ++ [attributes: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule TargetTraversal do
    @moduledoc false

    @enforce_keys [
      :relationship_id,
      :relationship_revision,
      :next_target_id,
      :next_target_revision,
      :evidence_ids,
      :reason
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ObservationTool do
    @moduledoc false

    @enforce_keys [
      :id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :provider_id,
      :provider_revision,
      :capability,
      :operation,
      :description,
      :input_schema,
      :output_schema,
      :verification_schema
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ProposalTool do
    @moduledoc false

    @enforce_keys [
      :id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :provider_id,
      :provider_revision,
      :request_kind,
      :capability,
      :operation,
      :description,
      :input_schema
    ]

    defstruct @enforce_keys ++ [evidence_requirements: []]
    @type t :: %__MODULE__{}
  end

  defmodule VerificationIntent do
    @moduledoc false
    @enforce_keys [:tool_id, :selectors, :parameters, :expected_result]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Proposal do
    @moduledoc false

    @enforce_keys [
      :tool_id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :request_kind,
      :capability,
      :operation,
      :selectors,
      :parameters,
      :reason,
      :evidence_ids
    ]

    defstruct @enforce_keys ++
                [affected_conditions: [], expected_result: %{}, verification_intent: nil]

    @type t :: %__MODULE__{}
  end

  def valid_affected_conditions?(%Proposal{} = proposal, conditions),
    do:
      valid_affected_conditions?(proposal.request_kind, proposal.affected_conditions, conditions)

  def valid_affected_conditions?(:observation, [], _conditions),
    do: true

  def valid_affected_conditions?(:effect, [], []),
    do: true

  def valid_affected_conditions?(:effect, claims, conditions)
      when is_list(claims) and claims != [] and is_list(conditions) do
    ids = Enum.map(claims, &if(is_map(&1), do: &1["condition_id"]))
    current = Map.new(conditions, &{&1.id, &1})

    length(claims) <= length(conditions) and length(ids) == MapSet.size(MapSet.new(ids)) and
      Enum.all?(claims, fn
        %{"condition_id" => id, "revision" => revision} = claim
        when is_binary(id) and is_integer(revision) and map_size(claim) == 2 ->
          case Map.get(current, id) do
            %Condition{revision: ^revision, state: :firing} -> true
            _other -> false
          end

        _other ->
          false
      end)
  end

  def valid_affected_conditions?(_kind, _claims, _conditions), do: false

  defmodule RecoveryConclusion do
    @moduledoc false
    @enforce_keys [:reason, :evidence_ids]
    defstruct @enforce_keys ++ [condition_claims: []]
    @type t :: %__MODULE__{}
  end

  defmodule CaseSplit do
    @moduledoc false
    @enforce_keys [:condition_ids, :evidence_ids, :remaining_evidence_ids, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Handoff do
    @moduledoc false
    @enforce_keys [:reason, :required_input]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Usage do
    @moduledoc false
    @enforce_keys [:input_tokens, :output_tokens]
    defstruct @enforce_keys ++ [cached_tokens: nil, reasoning_tokens: nil, finish_reason: nil]
    @type t :: %__MODULE__{}
  end

  defmodule ResolverDecision do
    @moduledoc false
    @enforce_keys [:intent, :usage]
    defstruct @enforce_keys ++ [condition_groups: []]
    @type t :: %__MODULE__{}
  end

  def normalize_condition_groups(groups, conditions, evidence) do
    available = MapSet.new(Enum.map(conditions, & &1.id))
    cited = MapSet.new(Enum.map(evidence, & &1.id))

    {accepted, assigned} =
      if(is_list(groups), do: Enum.take(groups, 32), else: [])
      |> Enum.reduce({[], MapSet.new()}, fn group, {accepted, assigned} ->
        case valid_group(group, available, cited, assigned) do
          {:ok, normalized} ->
            {[normalized | accepted],
             MapSet.union(assigned, MapSet.new(normalized["condition_ids"]))}

          :invalid ->
            {accepted, assigned}
        end
      end)

    missing =
      conditions
      |> Enum.reject(&MapSet.member?(assigned, &1.id))
      |> Enum.map(fn condition ->
        %{
          "condition_ids" => [condition.id],
          "assessment" => "unknown",
          "reason" => nil,
          "evidence_ids" => []
        }
      end)

    Enum.reverse(accepted) ++ missing
  end

  defp valid_group(
         %{
           "condition_ids" => ids,
           "assessment" => assessment,
           "reason" => reason,
           "evidence_ids" => evidence_ids
         },
         available,
         cited,
         assigned
       )
       when is_list(ids) and is_list(evidence_ids) and
              assessment in ["related", "independent", "unknown"] and
              is_binary(reason) do
    id_set = MapSet.new(ids)
    evidence_set = MapSet.new(evidence_ids)

    if ids != [] and length(ids) <= 32 and length(ids) == MapSet.size(id_set) and
         MapSet.subset?(id_set, available) and MapSet.disjoint?(id_set, assigned) and
         length(evidence_ids) <= 16 and length(evidence_ids) == MapSet.size(evidence_set) and
         MapSet.subset?(evidence_set, cited) and valid_resolver_reason?(reason) and
         (assessment == "unknown" or evidence_ids != []) do
      {:ok,
       %{
         "condition_ids" => ids,
         "assessment" => assessment,
         "reason" => reason,
         "evidence_ids" => evidence_ids
       }}
    else
      :invalid
    end
  end

  defp valid_group(_group, _available, _cited, _assigned), do: :invalid

  defmodule ResolverRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :case_id,
      :turn,
      :objective,
      :alert_state,
      :report_language,
      :disclosure,
      :budget,
      :evidence,
      :target_candidates,
      :observation_results,
      :target_relations,
      :observation_tools,
      :proposal_tools
    ]

    defstruct @enforce_keys ++
                [
                  selected_target_id: nil,
                  selected_target_revision: nil,
                  retry_context: nil,
                  traversable_relation_ids: [],
                  conditions: [],
                  historical_evidence: [],
                  recovery_evidence_ids: []
                ]

    @type t :: %__MODULE__{}
  end

  defmodule ReviewRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :resolver_session_id,
      :case_id,
      :objective,
      :report_language,
      :policy_summary,
      :proposal,
      :source_evidence,
      :cited_evidence,
      :budget
    ]

    defstruct @enforce_keys ++
                [
                  conditions: [],
                  initial_target_id: nil,
                  target_relations: [],
                  context_evidence: [],
                  retry_context: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule ReviewDecision do
    @moduledoc false
    @enforce_keys [:verdict, :reason, :usage]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule RecoveryReviewRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :resolver_session_id,
      :case_id,
      :objective,
      :report_language,
      :conditions,
      :source_evidence,
      :cited_evidence,
      :conclusion,
      :budget
    ]

    defstruct @enforce_keys ++ [context_evidence: [], retry_context: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Selection do
    @moduledoc false
    @enforce_keys [:role, :provider_id, :provider_revision, :source]
    defstruct @enforce_keys ++ [assignment_id: nil, assignment_revision: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error,
      class: :unknown,
      fields: [:category, :message, :usage, :dispatched?, :failure_code]

    @impl true
    def message(error), do: error.message
  end

  def resolver_disclosure_items(%ResolverRequest{} = request) do
    request.conditions ++
      request.evidence ++
      request.historical_evidence ++
      request.target_candidates ++
      request.observation_results ++
      request.target_relations ++ request.observation_tools ++ request.proposal_tools
  end

  def resolver_disclosure_size(%ResolverRequest{} = request) do
    encoded = %{
      context: %{
        objective: request.objective,
        alert_state: request.alert_state,
        report_language: request.report_language,
        retry_context: request.retry_context,
        traversable_relation_ids: request.traversable_relation_ids,
        recovery_evidence_ids: request.recovery_evidence_ids
      },
      items: Enum.map(resolver_disclosure_items(request), &plain_value/1)
    }

    case Jason.encode(encoded) do
      {:ok, value} -> byte_size(value)
      {:error, _error} -> :infinity
    end
  end

  defp plain_value(%_{} = value), do: value |> Map.from_struct() |> plain_value()

  defp plain_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, plain_value(nested)} end)

  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  defp plain_value(value), do: value

  @type invocation :: map()
  @type adapter_error ::
          {:error,
           :authentication
           | :unreachable
           | :timeout
           | :failed
           | :rate_limited
           | :cancelled
           | :invalid_output, String.t()}

  @type metered_adapter_error ::
          {:error, :invalid_output | :failed, String.t(), Usage.t()}

  @callback resolve(state :: term(), ResolverRequest.t(), invocation()) ::
              {:ok, ResolverDecision.t()} | adapter_error() | metered_adapter_error()
  @callback review(state :: term(), ReviewRequest.t(), invocation()) ::
              {:ok, ReviewDecision.t()} | adapter_error() | metered_adapter_error()

  @callback review_recovery(state :: term(), RecoveryReviewRequest.t(), invocation()) ::
              {:ok, ReviewDecision.t()} | adapter_error() | metered_adapter_error()
end
