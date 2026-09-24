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
    defstruct @enforce_keys ++ [target_id: nil]
    @type t :: %__MODULE__{}
  end

  def recovery_evidence_ids(request) do
    request.evidence
    |> Enum.filter(&verified_target_evidence?(&1, request.selected_target_id))
    |> Enum.map(& &1.id)
  end

  def recovery_ready?(%{alert_state: state} = request)
      when state in [:recovered, :not_applicable],
      do: recovery_evidence_ids(request) != []

  def recovery_ready?(_request), do: false

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

  defp proposal_requirements_available?(tool, request) do
    tool.request_kind == :observation or
      Enum.all?(tool.evidence_requirements, fn requirement ->
        matching_evidence(requirement, tool, request, nil) != []
      end)
  end

  defp matching_evidence(requirement, tool, request, evidence_ids) do
    observation_tool =
      Enum.find(request.observation_tools, fn observation ->
        observation.target_id == tool.target_id and
          observation.access_method_id == tool.access_method_id and
          observation.provider_id == tool.provider_id and
          observation.operation == requirement.observation
      end)

    if observation_tool do
      Enum.filter(request.evidence, fn evidence ->
        evidence.kind == "observation" and evidence.target_id == tool.target_id and
          is_map(evidence.content) and
          (is_nil(evidence_ids) or evidence.id in evidence_ids) and
          evidence.content["tool_id"] == observation_tool.id and
          is_map(evidence.content["facts"]) and
          Map.has_key?(evidence.content["facts"], requirement.fact)
      end)
    else
      []
    end
  end

  defp verified_target_evidence?(
         %Evidence{
           kind: "target_verification",
           target_id: target_id,
           content: %{"status" => "verified"}
         },
         target_id
       )
       when is_binary(target_id),
       do: true

  defp verified_target_evidence?(
         %Evidence{
           kind: "target_verification",
           target_id: nil,
           content: %{"status" => "verified"}
         },
         nil
       ),
       do: true

  defp verified_target_evidence?(
         %Evidence{
           kind: "observation",
           target_id: target_id,
           content: %{
             "status" => "applied",
             "category" => "target_observed",
             "facts" => facts,
             "recovery_eligible" => true
           }
         },
         target_id
       )
       when is_binary(target_id) and is_map(facts) and map_size(facts) > 0,
       do: true

  defp verified_target_evidence?(_evidence, _target_id), do: false

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

    defstruct @enforce_keys ++ [expected_result: %{}, verification_intent: nil]
    @type t :: %__MODULE__{}
  end

  defmodule RecoveryConclusion do
    @moduledoc false
    @enforce_keys [:reason, :evidence_ids]
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
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ResolverDecision do
    @moduledoc false
    @enforce_keys [:intent, :usage]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

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
                [selected_target_id: nil, selected_target_revision: nil, retry_context: nil]

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

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ReviewDecision do
    @moduledoc false
    @enforce_keys [:verdict, :reason, :usage]
    defstruct @enforce_keys
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
    use Splode.Error, class: :unknown, fields: [:category, :message, :usage, :dispatched?]

    @impl true
    def message(error), do: error.message
  end

  def resolver_disclosure_items(%ResolverRequest{} = request) do
    request.evidence ++
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
        retry_context: request.retry_context
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
end
