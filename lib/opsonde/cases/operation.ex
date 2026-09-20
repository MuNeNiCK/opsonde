defmodule Opsonde.Cases.Operation do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "operations"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:target_id]
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:mark_dispatching, from: :queued, to: :dispatching)
      transition(:record_no_send, from: :queued, to: :failed)

      transition(:record_outcome,
        from: :dispatching,
        to: [:applied, :failed, :partial, :unknown]
      )
    end
  end

  actions do
    defaults [:read]

    read :for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      prepare build(sort: [updated_at: :desc, id: :desc], limit: 100)
    end

    read :by_proposal do
      get? true
      argument :proposal_id, :uuid, allow_nil?: false
      filter expr(proposal_id == ^arg(:proposal_id))
    end

    create :create_record do
      accept [
        :id,
        :case_id,
        :resolution_run_id,
        :proposal_id,
        :approval_id,
        :actor_id,
        :target_id,
        :access_method_id,
        :provider_id,
        :case_generation,
        :authority_mode,
        :proposal_revision,
        :approval_proposal_revision,
        :actor_role_version,
        :target_revision,
        :access_method_revision,
        :provider_revision,
        :capability,
        :operation,
        :selectors,
        :parameters,
        :idempotency_key,
        :authorization_digest,
        :policy_context,
        :accepted_at
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :selectors}
      validate {Opsonde.Validations.BoundedMap, attribute: :parameters}
      validate {Opsonde.Validations.BoundedMap, attribute: :policy_context}
    end

    update :mark_dispatching do
      accept [:dispatch_started_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change transition_state(:dispatching)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [:status, :outcome_category, :reference, :result_details, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate present(:completed_at)
      validate present(:outcome_category)
      validate {Opsonde.Validations.BoundedMap, attribute: :result_details}
      change Opsonde.Cases.Operation.Changes.TransitionOutcome
      change optimistic_lock(:revision)
    end

    update :record_no_send do
      accept [:outcome_category, :result_details, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate present(:completed_at)
      validate present(:outcome_category)
      validate {Opsonde.Validations.BoundedMap, attribute: :result_details}
      change transition_state(:failed)
      change optimistic_lock(:revision)
    end

    action :accept, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run Opsonde.Cases.Operation.Actions.Accept
    end

    action :claim_dispatch, :struct do
      constraints instance_of: Opsonde.Cases.OperationClaim
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Opsonde.Cases.Operation.Actions.ClaimDispatch
    end
  end

  policies do
    policy action([
             :by_proposal,
             :create_record,
             :mark_dispatching,
             :record_outcome,
             :record_no_send,
             :accept,
             :claim_dispatch
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
    uuid_primary_key :id, writable?: true

    attribute :case_generation, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :authority_mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ask, :auto, :full_access]]

    attribute :proposal_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :approval_proposal_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

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

    attribute :idempotency_key, :string,
      allow_nil?: false,
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

    attribute :reference, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :result_details, :map, allow_nil?: false, public?: true, default: %{}
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case, allow_nil?: false, public?: true
    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun, allow_nil?: false, public?: true
    belongs_to :proposal, Opsonde.Cases.Proposal, allow_nil?: false, public?: true
    belongs_to :approval, Opsonde.Cases.Approval, allow_nil?: false, public?: true
    belongs_to :actor, Opsonde.Accounts.User, allow_nil?: false, public?: true
    belongs_to :target, Opsonde.Targets.Target, allow_nil?: false, public?: true
    belongs_to :access_method, Opsonde.Targets.AccessMethod, allow_nil?: false, public?: true
    belongs_to :provider, Opsonde.Providers.Provider, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_proposal, [:proposal_id]
    identity :unique_idempotency, [:idempotency_key]
  end
end
