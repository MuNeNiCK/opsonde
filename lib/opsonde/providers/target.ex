defmodule Opsonde.Providers.Target do
  @moduledoc false

  defmodule Operation do
    @moduledoc false
    @enforce_keys [:capability, :operation, :description, :input_schema]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            capability: String.t(),
            operation: String.t(),
            description: String.t(),
            input_schema: map()
          }
  end

  defmodule Capabilities do
    @moduledoc false
    @enforce_keys [:observations, :effects]
    defstruct [:observations, :effects]
    @type t :: %__MODULE__{observations: [Operation.t()], effects: [Operation.t()]}
  end

  defmodule ObservationRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :capability,
      :operation,
      :authorization_digest
    ]

    defstruct @enforce_keys ++ [selectors: %{}, parameters: %{}, max_attempts: 1]
    @type t :: %__MODULE__{}
  end

  defmodule Observation do
    @moduledoc false
    @enforce_keys [:facts, :observed_at]
    defstruct @enforce_keys ++ [evidence: []]
    @type t :: %__MODULE__{}
  end

  defmodule EffectRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id,
      :idempotency_key
    ]

    defstruct @enforce_keys ++ [selectors: %{}, parameters: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule EffectResult do
    @moduledoc false
    @enforce_keys [:status]
    defstruct @enforce_keys ++ [reference: nil, details: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule VerificationRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id
    ]

    defstruct @enforce_keys ++ [selectors: %{}, parameters: %{}, reference: nil, expected: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule Verification do
    @moduledoc false
    @enforce_keys [:status, :observed_at]
    defstruct @enforce_keys ++ [facts: %{}, evidence: []]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @type invocation :: map()
  @type read_error :: {:error, :retryable | :timeout | :failed | :cancelled, String.t()}
  @type effect_error :: {:error, :failed | :cancelled, String.t()}

  @callback capabilities(state :: term(), invocation()) ::
              {:ok, Capabilities.t()} | read_error()
  @callback observe(state :: term(), ObservationRequest.t(), invocation()) ::
              {:ok, Observation.t()} | read_error()
  @callback effect(state :: term(), EffectRequest.t(), invocation()) ::
              {:ok, EffectResult.t()} | effect_error()
  @callback verify(state :: term(), VerificationRequest.t(), invocation()) ::
              {:ok, Verification.t()} | read_error()
end
