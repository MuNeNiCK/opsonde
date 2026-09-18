defmodule Opsonde.Cases.VerificationAttempt do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "verification_attempts"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    read :for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      prepare build(sort: [updated_at: :desc, id: :desc], limit: 100)
    end

    read :by_operation do
      get? true
      argument :operation_id, :uuid, allow_nil?: false
      filter expr(operation_id == ^arg(:operation_id))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :operation_id,
        :proposal_id,
        :actor_id,
        :target_id,
        :access_method_id,
        :provider_id,
        :status,
        :case_generation,
        :authority_mode,
        :actor_role_version,
        :target_revision,
        :access_method_revision,
        :provider_revision,
        :tool_id,
        :capability,
        :operation,
        :selectors,
        :parameters,
        :expected,
        :operation_reference,
        :authorization_digest,
        :policy_context,
        :accepted_at,
        :revision
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :selectors}
      validate {Opsonde.Validations.BoundedMap, attribute: :parameters}
      validate {Opsonde.Validations.BoundedMap, attribute: :expected}
      validate {Opsonde.Validations.BoundedMap, attribute: :policy_context}
    end

    update :mark_dispatching do
      accept [:dispatch_started_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :queued)
      validate Opsonde.Validations.CurrentRevision
      change set_attribute(:status, :dispatching)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [
        :status,
        :outcome_category,
        :facts,
        :provider_evidence,
        :observed_at,
        :completed_at
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :dispatching)
      validate Opsonde.Validations.CurrentRevision
      validate attribute_in(:status, [:verified, :not_verified, :unknown])
      validate present(:outcome_category)
      validate present(:observed_at)
      validate present(:completed_at)
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
      validate {Opsonde.Validations.BoundedMap, attribute: :provider_evidence}
      change optimistic_lock(:revision)
    end

    update :record_no_send do
      accept [:outcome_category, :facts, :provider_evidence, :observed_at, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :queued)
      validate Opsonde.Validations.CurrentRevision
      validate present(:outcome_category)
      validate present(:observed_at)
      validate present(:completed_at)
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
      validate {Opsonde.Validations.BoundedMap, attribute: :provider_evidence}
      change set_attribute(:status, :unknown)
      change optimistic_lock(:revision)
    end

    action :accept, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :operation_id, :uuid, allow_nil?: false
      run Opsonde.Cases.VerificationAttempt.Actions.Accept
    end

    action :claim_dispatch, :struct do
      constraints instance_of: Opsonde.Cases.VerificationClaim
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Opsonde.Cases.VerificationAttempt.Actions.ClaimDispatch
    end

    action :evaluate, :struct do
      constraints instance_of: Opsonde.Cases.Turn
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Opsonde.Cases.VerificationAttempt.Actions.Evaluate
    end
  end

  policies do
    policy action([
             :by_operation,
             :create_record,
             :mark_dispatching,
             :record_outcome,
             :record_no_send,
             :accept,
             :claim_dispatch,
             :evaluate
           ]) do
      forbid_if always()
    end

    policy action([:read, :for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:queued, :dispatching, :verified, :not_verified, :unknown]]

    attribute :case_generation, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :authority_mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ask, :auto, :full_access]]

    attribute :actor_role_version, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :target_revision, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :access_method_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :provider_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :tool_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :capability, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :operation, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :selectors, :map, allow_nil?: false, public?: true
    attribute :parameters, :map, allow_nil?: false, public?: true
    attribute :expected, :map, allow_nil?: false, public?: true

    attribute :operation_reference, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :authorization_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :policy_context, :map, allow_nil?: false, public?: true
    attribute :accepted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :dispatch_started_at, :utc_datetime_usec, public?: true

    attribute :outcome_category, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :facts, :map, allow_nil?: false, public?: true, default: %{}
    attribute :provider_evidence, :map, allow_nil?: false, public?: true, default: %{}
    attribute :observed_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case, allow_nil?: false, public?: true
    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun, allow_nil?: false, public?: true

    belongs_to :operation_record, Opsonde.Cases.Operation,
      source_attribute: :operation_id,
      destination_attribute: :id,
      allow_nil?: false,
      public?: true

    belongs_to :proposal, Opsonde.Cases.Proposal, allow_nil?: false, public?: true
    belongs_to :actor, Opsonde.Accounts.User, allow_nil?: false, public?: true
    belongs_to :target, Opsonde.Targets.Target, allow_nil?: false, public?: true
    belongs_to :access_method, Opsonde.Targets.AccessMethod, allow_nil?: false, public?: true
    belongs_to :provider, Opsonde.Providers.Provider, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_operation, [:operation_id]
  end
end
