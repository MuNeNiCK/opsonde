defmodule Opsonde.Cases.AIInvocation do
  alias Opsonde.Providers.AI

  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ai_invocations"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:turn_id]
      index [:proposal_id]
    end
  end

  actions do
    defaults [:read]

    read :by_idempotency do
      get? true
      argument :idempotency_key, :string, allow_nil?: false
      filter expr(idempotency_key == ^arg(:idempotency_key))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :turn_id,
        :proposal_id,
        :provider_id,
        :assignment_id,
        :role,
        :idempotency_key,
        :request_digest,
        :provider_revision,
        :assignment_revision,
        :selection_source,
        :reserved_units,
        :dispatch_started_at
      ]

      change set_attribute(:status, :dispatching)
      validate Opsonde.Cases.AIInvocation.Validations.Subject
    end

    update :record_outcome do
      accept [
        :status,
        :input_tokens,
        :output_tokens,
        :cached_tokens,
        :reasoning_tokens,
        :finish_reason,
        :category,
        :failure_code,
        :rejection_path,
        :result_digest,
        :completed_at
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate changing(:status, from: :dispatching)
      validate attribute_in(:status, [:completed, :failed, :unknown])
      validate present(:completed_at)
      change optimistic_lock(:revision)
    end

    action :claim, :struct do
      constraints instance_of: Opsonde.Cases.AIInvocation.Claim
      transaction? false
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:resolver, :reviewer]]
      argument :case_id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :turn_id, :uuid
      argument :expected_turn_revision, :integer, constraints: [min: 1]
      argument :proposal_id, :uuid
      argument :expected_proposal_revision, :integer, constraints: [min: 1]
      argument :provider_id, :uuid, allow_nil?: false
      argument :assignment_id, :uuid, allow_nil?: false
      argument :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :assignment_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :selection_source, :atom,
        allow_nil?: false,
        constraints: [one_of: [:assignment]]

      argument :request_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      argument :delivery_attempt, :integer, constraints: [min: 1]

      run Opsonde.Cases.AIInvocation.Actions.Claim
    end
  end

  policies do
    policy action([:read, :by_idempotency, :create_record, :record_outcome, :claim]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:resolver, :reviewer]]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:dispatching, :completed, :failed, :unknown]]

    attribute :idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 500]

    attribute :request_digest, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :assignment_revision, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :selection_source, :atom,
      allow_nil?: false,
      constraints: [one_of: [:assignment]]

    attribute :reserved_units, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :cached_tokens, :integer, constraints: [min: 0]
    attribute :reasoning_tokens, :integer, constraints: [min: 0]
    attribute :finish_reason, :string, constraints: [min_length: 1, max_length: 40]
    attribute :category, :string, constraints: [min_length: 1, max_length: 120]
    attribute :failure_code, :string, constraints: [min_length: 1, max_length: 120]

    attribute :rejection_path, :string,
      constraints: [max_length: 200, length_count: :bytes, match: ~r/\A\//, trim?: false]

    attribute :result_digest, :string, constraints: [min_length: 64, max_length: 64]
    attribute :dispatch_started_at, :utc_datetime_usec, allow_nil?: false
    attribute :completed_at, :utc_datetime_usec
    attribute :revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case, allow_nil?: false
    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun, allow_nil?: false
    belongs_to :turn, Opsonde.Cases.Turn
    belongs_to :proposal, Opsonde.Cases.Proposal
    belongs_to :provider, Opsonde.Providers.Provider, allow_nil?: false
    belongs_to :assignment, Opsonde.Providers.AIUsageRoleAssignment, allow_nil?: false
  end

  identities do
    identity :unique_idempotency, [:idempotency_key]
  end

  def request_digest(request) do
    request
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def rejection_path(error) do
    case find_ai_error(error) do
      %AI.Error{failure_path: path} when is_binary(path) -> path
      _other -> nil
    end
  end

  def retry_context([]), do: nil

  def retry_context(failures) do
    latest = Enum.max_by(failures, & &1.completed_at, DateTime)

    context = %{
      "category" => "invalid_output",
      "rejection_code" => latest.failure_code || "invalid_output"
    }

    if latest.rejection_path,
      do: Map.put(context, "rejection_path", latest.rejection_path),
      else: context
  end

  def failure_accounting(error, reserved_units) do
    ai_error = find_ai_error(error)

    usage =
      case ai_error do
        %AI.Error{usage: %AI.Usage{} = value} -> value
        _other -> nil
      end

    dispatched? = match?(%AI.Error{dispatched?: true}, ai_error)

    failure_accounting(usage, dispatched?, reserved_units)
    |> Map.put(:ai_error, ai_error)
  end

  def failure_accounting(%AI.Usage{} = usage, _dispatched?, _reserved_units) do
    %{amount: usage.input_tokens + usage.output_tokens, usage: usage}
  end

  def failure_accounting(nil, true, reserved_units),
    do: %{amount: reserved_units, usage: nil}

  def failure_accounting(nil, _dispatched?, _reserved_units),
    do: %{amount: 0, usage: nil}

  defp find_ai_error(%AI.Error{} = error), do: error

  defp find_ai_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_ai_error/1)

  defp find_ai_error(_error), do: nil
end
