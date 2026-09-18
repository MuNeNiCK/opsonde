defmodule Opsonde.Cases.Turn do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "turns"
    repo Opsonde.Repo
    identity_wheres_to_sql one_started_turn: "status = 'started'"

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
    end
  end

  actions do
    defaults [:read]

    read :by_idempotency do
      get? true
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(
               resolution_run_id == ^arg(:resolution_run_id) and
                 idempotency_key == ^arg(:idempotency_key)
             )
    end

    read :started_for_run do
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(resolution_run_id == ^arg(:resolution_run_id) and status == :started)
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :ordinal,
        :idempotency_key,
        :status,
        :intent,
        :result,
        :result_digest,
        :progress_kind,
        :started_at,
        :completed_at
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :intent}
      validate {Opsonde.Validations.BoundedMap, attribute: :result}
    end

    update :complete_record do
      accept [:result, :result_digest, :progress_kind, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate attribute_equals(:status, :started)
      validate {Opsonde.Validations.BoundedMap, attribute: :result}
      change set_attribute(:status, :completed)
      change optimistic_lock(:revision)
    end

    action :start, :struct do
      constraints instance_of: Opsonde.Cases.BudgetResult
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :intent, :map, allow_nil?: false
      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Opsonde.Cases.Turn.Actions.Start
    end

    action :complete, :struct do
      constraints instance_of: Opsonde.Cases.BudgetResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :result, :map, allow_nil?: false

      argument :progress_kind, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:evidence, :hypothesis, :proposal, :source_change, :human_input, :none]
        ]

      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Opsonde.Cases.Turn.Actions.Complete
    end
  end

  policies do
    policy action([
             :by_idempotency,
             :started_for_run,
             :create_record,
             :complete_record,
             :start,
             :complete
           ]) do
      forbid_if always()
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ordinal, :integer do
      allow_nil? false
      public? true
    end

    attribute :idempotency_key, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:started, :completed]
    end

    attribute :intent, :map do
      allow_nil? false
      public? true
    end

    attribute :result, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :result_digest, :string do
      public? true
    end

    attribute :progress_kind, :atom do
      public? true
      constraints one_of: [:evidence, :hypothesis, :proposal, :source_change, :human_input, :none]
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_idempotency, [:resolution_run_id, :idempotency_key]
    identity :unique_ordinal, [:resolution_run_id, :ordinal]

    identity :one_started_turn, [:resolution_run_id] do
      where expr(status == :started)
    end
  end
end
