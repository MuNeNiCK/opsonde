defmodule Opsonde.Providers.AI do
  @moduledoc false

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

  defmodule ObservationResult do
    @moduledoc false
    @enforce_keys [:id, :tool_id, :target_id, :kind, :status, :content]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetRelation do
    @moduledoc false
    @enforce_keys [:id, :source_target_id, :target_target_id, :kind]
    defstruct @enforce_keys ++ [attributes: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule ObservationTool do
    @moduledoc false
    @enforce_keys [:id, :target_id, :capability, :description, :input_schema]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ObservationChoice do
    @moduledoc false
    @enforce_keys [:tool_id, :parameters, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ProposalTool do
    @moduledoc false
    @enforce_keys [:id, :target_id, :capability, :description, :input_schema]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Proposal do
    @moduledoc false

    @enforce_keys [
      :tool_id,
      :target_id,
      :capability,
      :parameters,
      :reason,
      :evidence_ids,
      :expected_result,
      :verification_intent
    ]

    defstruct @enforce_keys
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
      :disclosure,
      :budget,
      :evidence,
      :observation_results,
      :target_relations,
      :observation_tools,
      :proposal_tools
    ]

    defstruct @enforce_keys
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
      :policy_summary,
      :proposal,
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
    use Splode.Error, class: :unknown, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @type invocation :: map()
  @type adapter_error ::
          {:error,
           :authentication | :unreachable | :timeout | :failed | :rate_limited | :cancelled,
           String.t()}

  @callback resolve(state :: term(), ResolverRequest.t(), invocation()) ::
              {:ok, ResolverDecision.t()} | adapter_error()
  @callback review(state :: term(), ReviewRequest.t(), invocation()) ::
              {:ok, ReviewDecision.t()} | adapter_error()
end
