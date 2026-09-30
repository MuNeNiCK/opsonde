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

    # The same typed value crosses the role port and the Method persistence seam.
    def constraints do
      operation = [
        instance_of: Operation,
        fields: [
          capability: [type: :string, allow_nil?: false],
          operation: [type: :string, allow_nil?: false],
          description: [type: :string, allow_nil?: false],
          input_schema: [type: :map, allow_nil?: false],
          output_schema: [type: :map],
          verification_schema: [type: :map],
          evidence_requirements: [
            type: {:array, :struct},
            allow_nil?: false,
            constraints: [
              items: [
                instance_of: EvidenceRequirement,
                fields: [
                  parameter: [type: :string, allow_nil?: false],
                  fact: [type: :string, allow_nil?: false],
                  observation: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      ]

      [
        instance_of: __MODULE__,
        fields: [
          observations: [
            type: {:array, :struct},
            allow_nil?: false,
            constraints: [items: operation]
          ],
          effects: [type: {:array, :struct}, allow_nil?: false, constraints: [items: operation]]
        ]
      ]
    end
  end

  defmodule Connection do
    @moduledoc false
    @enforce_keys [:endpoint]
    defstruct @enforce_keys
    @type t :: %__MODULE__{endpoint: String.t()}
  end

  defmodule FileReference do
    @moduledoc false
    @fields ~w(id target_id name media_type size_bytes sha256)a
    @keys Enum.map(@fields, &Atom.to_string/1)

    # Pure wire value shared by storage and protocol ports; it performs no I/O.
    def from_metadata(metadata),
      do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(metadata, &1)})

    def valid?(reference) when is_map(reference) do
      Enum.sort(Map.keys(reference)) == Enum.sort(@keys) and
        valid_id?(reference["id"]) and valid_id?(reference["target_id"]) and
        bounded_text?(reference["name"], 255) and
        bounded_text?(reference["media_type"], 256) and
        not String.contains?(reference["media_type"], ["\r", "\n"]) and
        is_integer(reference["size_bytes"]) and reference["size_bytes"] >= 0 and
        is_binary(reference["sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, reference["sha256"])
    end

    def valid?(_reference), do: false

    def valid_set?(files) when is_map(files) and map_size(files) <= 100 do
      Enum.all?(files, fn {label, reference} ->
        is_binary(label) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,119}\z/, label) and
          valid?(reference)
      end)
    end

    def valid_set?(_files), do: false

    def split(parameters) do
      {files, parameters} = Map.pop(parameters, "files", %{})
      if valid_set?(files), do: {:ok, parameters, files}, else: {:error, :invalid_files}
    end

    defp valid_id?(id), do: is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id))

    defp bounded_text?(value, maximum),
      do:
        is_binary(value) and String.valid?(value) and
          length(String.codepoints(value)) in 1..maximum
  end

  defmodule FileWriter do
    @moduledoc false
    @enforce_keys [:id, :status, :offset, :chunk_bytes, :append, :complete, :abort]
    defstruct @enforce_keys
  end

  defmodule AccessMethodProfile do
    @moduledoc false
    @enforce_keys [:method, :capabilities]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            method: String.t(),
            capabilities: [String.t()]
          }
  end

  defmodule CapabilitiesRequest do
    @moduledoc false
    @enforce_keys [:provider_revision, :connection]
    defstruct @enforce_keys
    @type t :: %__MODULE__{provider_revision: pos_integer(), connection: Connection.t()}
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
    defstruct @enforce_keys ++ [files: %{}]
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
                  files: %{},
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
                  files: %{},
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
                  files: %{},
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
  @callback bind_connection(state :: term(), Connection.t()) ::
              {:ok, term()} | {:error, :failed, String.t()}
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
      bounded_map?(request.selectors) and bounded_map?(request.parameters) and
      FileReference.valid_set?(request.files)
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
