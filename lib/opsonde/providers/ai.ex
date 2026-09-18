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
    @enforce_keys [:remaining_turns, :remaining_tokens]
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
    @enforce_keys [:tool_id, :target_id, :kind, :status, :content]
    defstruct @enforce_keys
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

  defmodule Finding do
    @moduledoc false
    @enforce_keys [:summary, :confidence, :evidence_ids]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Proposal do
    @moduledoc false
    @enforce_keys [:tool_id, :target_id, :capability, :parameters, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Usage do
    @moduledoc false
    @enforce_keys [:input_tokens, :output_tokens]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Decision do
    @moduledoc false
    @enforce_keys [:usage]
    defstruct @enforce_keys ++ [next_observation: nil, findings: [], proposals: []]
    @type t :: %__MODULE__{}
  end

  defmodule Request do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :objective,
      :disclosure,
      :budget,
      :evidence,
      :observation_results,
      :tools,
      :proposal_tools
    ]

    defstruct @enforce_keys
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

  @callback decide(state :: term(), Request.t(), invocation()) ::
              {:ok, Decision.t()} | adapter_error()
end
