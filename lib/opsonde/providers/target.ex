defmodule Opsonde.Providers.Target do
  @moduledoc false

  defmodule EvidenceRequirement do
    @moduledoc false
    @enforce_keys [:parameter, :fact, :observation]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            parameter: String.t(),
            fact: String.t(),
            observation: String.t()
          }
  end

  defmodule Operation do
    @moduledoc false
    @enforce_keys [:capability, :operation, :description, :input_schema]
    defstruct @enforce_keys ++
                [
                  output_schema: nil,
                  verification_schema: nil,
                  evidence_requirements: []
                ]

    @type t :: %__MODULE__{
            capability: String.t(),
            operation: String.t(),
            description: String.t(),
            input_schema: map(),
            output_schema: map() | nil,
            verification_schema: map() | nil,
            evidence_requirements: [EvidenceRequirement.t()]
          }
  end

  defmodule Capabilities do
    @moduledoc false
    @enforce_keys [:observations, :effects]
    defstruct [:observations, :effects]
    @type t :: %__MODULE__{observations: [Operation.t()], effects: [Operation.t()]}
  end

  defmodule Connection do
    @moduledoc false
    @enforce_keys [:endpoint]
    defstruct @enforce_keys
    @type t :: %__MODULE__{endpoint: String.t()}
  end

  defmodule AccessMethodProfile do
    @moduledoc false
    @enforce_keys [:method, :capabilities]
    defstruct @enforce_keys ++
                [
                  configuration_endpoint?: false,
                  required_capabilities: []
                ]

    @type t :: %__MODULE__{
            method: String.t(),
            capabilities: [String.t()],
            configuration_endpoint?: boolean(),
            required_capabilities: [String.t()]
          }
  end

  defmodule MethodRequest do
    @moduledoc false
    @enforce_keys [
      :provider_revision,
      :connection,
      :capability,
      :operation,
      :selectors,
      :parameters
    ]
    defstruct @enforce_keys
  end

  defmodule RequestClassification do
    @moduledoc false
    @enforce_keys [:kind]
    defstruct @enforce_keys
  end

  defmodule ObservationRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :connection,
      :capability,
      :operation,
      :authorization_digest
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  max_attempts: 1,
                  authority_mode: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule Observation do
    @moduledoc false
    @enforce_keys [:facts, :observed_at]
    defstruct @enforce_keys ++ [evidence: [], state_facts: nil]
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
      :connection,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id,
      :idempotency_key
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  authority_mode: nil
                ]

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
      :connection,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  reference: nil,
                  expected: %{}
                ]

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
  @callback resource_scope(operation :: String.t(), capability :: String.t(), selectors :: map()) ::
              String.t()

  @callback access_method_profile() :: AccessMethodProfile.t() | :unrestricted

  @callback classify_request(state :: term(), MethodRequest.t()) ::
              {:ok, :observation | :effect} | {:error, :failed, String.t()}

  @optional_callbacks resource_scope: 3

  def classify_request(adapter, state, %MethodRequest{} = request) when is_atom(adapter) do
    cond do
      not valid_method_request?(request) ->
        {:error, :failed, "Target Method request is invalid"}

      not function_exported?(adapter, :classify_request, 2) ->
        {:error, :failed, "Target classifier is unavailable"}

      true ->
        classify_with_adapter(adapter, state, request)
    end
  end

  def classify_request(_adapter, _state, _request),
    do: {:error, :failed, "Target Method request is invalid"}

  defp classify_with_adapter(adapter, state, request) do
    case adapter.classify_request(state, request) do
      {:ok, kind} when kind in [:observation, :effect] ->
        {:ok, %RequestClassification{kind: kind}}

      {:error, :failed, reason} when is_binary(reason) and byte_size(reason) in 1..500 ->
        {:error, :failed, reason}

      _other ->
        {:error, :failed, "Target classifier returned an invalid result"}
    end
  rescue
    _error -> {:error, :failed, "Target classifier returned an invalid result"}
  catch
    _kind, _reason -> {:error, :failed, "Target classifier returned an invalid result"}
  end

  defp valid_method_request?(%MethodRequest{} = request) do
    is_integer(request.provider_revision) and request.provider_revision > 0 and
      match?(%Connection{}, request.connection) and
      bounded_binary?(request.connection.endpoint, 1_024) and
      bounded_binary?(request.capability, 120) and
      bounded_binary?(request.operation, 120) and
      bounded_map?(request.selectors) and bounded_map?(request.parameters)
  end

  defp bounded_binary?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_map?(value) when is_map(value) and map_size(value) <= 100 do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= 65_536
      {:error, _reason} -> false
    end
  end

  defp bounded_map?(_value), do: false

  def capability_names(%Capabilities{} = capabilities) do
    (capabilities.observations ++ capabilities.effects)
    |> Enum.map(& &1.capability)
    |> Enum.uniq()
  end
end
