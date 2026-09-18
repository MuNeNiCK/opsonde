defmodule Opsonde.Cases.Report do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "reports"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [generated_at: :desc, id: :desc])
    end

    read :by_case_revision do
      get? true
      argument :case_id, :uuid, allow_nil?: false
      argument :case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(case_id == ^arg(:case_id) and case_revision == ^arg(:case_revision))
    end

    create :create_record do
      accept [
        :case_id,
        :case_revision,
        :language,
        :outcome,
        :content,
        :content_digest,
        :generated_at
      ]

      validate {Opsonde.Validations.BoundedMap,
                attribute: :content, max_fields: 20, max_bytes: 10_485_760}
    end

    action :generate, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run Opsonde.Cases.Report.Actions.Generate
    end
  end

  policies do
    policy action([:by_case_revision, :create_record]) do
      forbid_if always()
    end

    policy action(:generate) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :case_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :language, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:en, :ja]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:resolved, :needs_attention, :cancelled]
    end

    attribute :content, :map do
      allow_nil? false
      public? true
    end

    attribute :content_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :generated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_case_revision, [:case_id, :case_revision]
  end
end
