defmodule Opsonde.Cases.ReviewDecision do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "review_decisions"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:provider_id]
      index [:assignment_id]
    end
  end

  actions do
    defaults [:read]

    read :by_proposal do
      get? true
      argument :proposal_id, :uuid, allow_nil?: false
      filter expr(proposal_id == ^arg(:proposal_id))
    end

    create :create_record do
      accept [
        :proposal_id,
        :case_id,
        :resolution_run_id,
        :provider_id,
        :assignment_id,
        :outcome,
        :verdict,
        :category,
        :reason,
        :selection_source,
        :provider_revision,
        :assignment_revision,
        :session_id,
        :resolver_session_id,
        :proposal_digest,
        :input_tokens,
        :output_tokens,
        :result_digest,
        :decided_at
      ]
    end
  end

  policies do
    policy action([:by_proposal, :create_record]) do
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

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:decision, :delivery_failed]
    end

    attribute :verdict, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approved, :rejected, :needs_human]
    end

    attribute :category, :string do
      public? true
      constraints max_length: 80
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1_000
    end

    attribute :selection_source, :atom do
      public? true
      constraints one_of: [:assignment, :resolver_fallback]
    end

    attribute :provider_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :assignment_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :session_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :resolver_session_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :proposal_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :input_tokens, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :output_tokens, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :result_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :proposal, Opsonde.Cases.Proposal do
      allow_nil? false
      public? true
    end

    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun do
      allow_nil? false
      public? true
    end

    belongs_to :provider, Opsonde.Providers.Provider do
      public? true
    end

    belongs_to :assignment, Opsonde.Providers.AIUsageRoleAssignment do
      public? true
    end
  end

  identities do
    identity :unique_proposal, [:proposal_id]
  end
end
