defmodule Opsonde.Cases.Proposal do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "proposals"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:target_id]
      index [:proposed_for_id]
    end
  end

  actions do
    defaults [:read]

    read :for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      prepare build(sort: [updated_at: :desc, id: :desc], limit: 100)
    end

    read :by_source_turn do
      get? true
      argument :source_turn_id, :uuid, allow_nil?: false
      filter expr(source_turn_id == ^arg(:source_turn_id))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :source_turn_id,
        :proposed_for_id,
        :target_id,
        :access_method_id,
        :provider_id,
        :status,
        :authority_mode,
        :case_generation,
        :target_revision,
        :access_method_revision,
        :provider_revision,
        :request_kind,
        :tool_id,
        :capability,
        :operation,
        :selectors,
        :parameters,
        :reason,
        :evidence_ids,
        :expected_result,
        :verification_intent,
        :verification_tool,
        :resolver_identity,
        :reserved_operation_id,
        :operation_idempotency_key,
        :preflight_status,
        :preflight_context,
        :preflight_reason,
        :proposal_digest,
        :expires_at,
        :revision
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :selectors}
      validate {Opsonde.Validations.BoundedMap, attribute: :parameters}
      validate {Opsonde.Validations.BoundedMap, attribute: :expected_result}
      validate {Opsonde.Validations.BoundedMap, attribute: :verification_intent}
      validate {Opsonde.Validations.BoundedMap, attribute: :verification_tool}
      validate {Opsonde.Validations.BoundedMap, attribute: :resolver_identity}
      validate {Opsonde.Validations.BoundedMap, attribute: :preflight_context}
    end

    update :transition do
      accept [:status]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :materialize, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Opsonde.Cases.Proposal.Actions.Materialize
    end

    action :route_authority, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Proposal.Actions.Authority, operation: :route}
    end

    action :decide, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :proposal_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      argument :decision, :atom,
        allow_nil?: false,
        constraints: [one_of: [:approved, :rejected]]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run {Opsonde.Cases.Proposal.Actions.Authority, operation: :decide}
    end

    action :apply_review, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      argument :review_decision_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Proposal.Actions.Authority, operation: :review}
    end
  end

  policies do
    policy action([
             :by_source_turn,
             :create_record,
             :transition,
             :materialize,
             :route_authority,
             :apply_review
           ]) do
      forbid_if always()
    end

    policy action(:decide) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :proposed,
                    :blocked,
                    :recommended,
                    :awaiting_human,
                    :reviewing,
                    :authorized,
                    :rejected,
                    :invalidated
                  ]
    end

    attribute :authority_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:readonly, :ask, :auto, :full_access]
    end

    attribute :case_generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :target_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :access_method_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :provider_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :request_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:observation, :effect]
    end

    attribute :tool_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :capability, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :operation, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :selectors, :map do
      allow_nil? false
      public? true
    end

    attribute :parameters, :map do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :evidence_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      constraints min_length: 0, max_length: 100
    end

    attribute :expected_result, :map do
      allow_nil? false
      public? true
    end

    attribute :verification_intent, :map do
      allow_nil? false
      public? true
    end

    attribute :verification_tool, :map do
      allow_nil? false
      public? true
    end

    attribute :resolver_identity, :map do
      allow_nil? false
      public? true
    end

    attribute :reserved_operation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :operation_idempotency_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :preflight_status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:cleared, :blocked]
    end

    attribute :preflight_context, :map do
      allow_nil? false
      public? true
    end

    attribute :preflight_reason, :string do
      public? true
      constraints max_length: 500
    end

    attribute :proposal_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
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

    belongs_to :source_turn, Opsonde.Cases.Turn do
      allow_nil? false
      public? true
    end

    belongs_to :proposed_for, Opsonde.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :target, Opsonde.Targets.Target do
      allow_nil? false
      public? true
    end

    belongs_to :access_method, Opsonde.Targets.AccessMethod do
      allow_nil? false
      public? true
    end

    belongs_to :provider, Opsonde.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_turn, [:source_turn_id]
    identity :unique_reserved_operation, [:reserved_operation_id]
  end
end
