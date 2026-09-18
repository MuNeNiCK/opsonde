defmodule Opsonde.Targets.Target do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "targets"
    repo Opsonde.Repo

    custom_indexes do
      index [:management_boundary_id]
    end
  end

  actions do
    defaults [:read]

    read :search_index do
      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      filter expr(active == true and contains(search_text, ^arg(:query)))
      prepare build(sort: [name: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:name, :kind, :platform, :facts, :management_boundary_id]
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
      change {Opsonde.Targets.Changes.BuildSearchText, fields: [:name, :kind, :platform, :facts]}
    end

    update :update do
      primary? true
      accept [:name, :kind, :platform, :facts, :management_boundary_id]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
      change {Opsonde.Targets.Changes.BuildSearchText, fields: [:name, :kind, :platform, :facts]}
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end

    action :search, :struct do
      constraints instance_of: Opsonde.Targets.SearchResult

      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      argument :max_results, :integer,
        allow_nil?: false,
        default: 20,
        constraints: [min: 1, max: 50]

      run Opsonde.Targets.Target.Actions.Search
    end
  end

  policies do
    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:search_index) do
      forbid_if always()
    end

    policy action(:search) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :platform, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :facts, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :search_text, :string do
      allow_nil? false
      public? false
      constraints max_length: 65_536
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :management_boundary, Opsonde.Targets.ManagementBoundary do
      public? true
    end

    has_many :external_identities, Opsonde.Targets.ExternalIdentity
    has_many :access_methods, Opsonde.Targets.AccessMethod

    has_many :outgoing_relationships, Opsonde.Targets.Relationship do
      destination_attribute :source_target_id
    end

    has_many :incoming_relationships, Opsonde.Targets.Relationship do
      destination_attribute :destination_target_id
    end
  end
end
