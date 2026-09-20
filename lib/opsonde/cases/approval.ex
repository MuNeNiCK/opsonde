defmodule Opsonde.Cases.Approval do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "approvals"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:actor_id]
    end
  end

  actions do
    defaults [:read]

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [decided_at: :asc, id: :asc])
    end

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
        :actor_id,
        :actor_role_version,
        :decision,
        :source,
        :proposal_digest,
        :proposal_revision,
        :case_generation,
        :clearance_digest,
        :reason,
        :decided_at
      ]
    end
  end

  policies do
    policy action([:by_proposal, :create_record]) do
      forbid_if always()
    end

    policy action([:read, :page_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :decision, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approved, :rejected]
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :readonly, :full_access, :reviewer]
    end

    attribute :proposal_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :proposal_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :case_generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :actor_role_version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :clearance_digest, :string do
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1_000
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

    belongs_to :actor, Opsonde.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_proposal, [:proposal_id]
  end
end
