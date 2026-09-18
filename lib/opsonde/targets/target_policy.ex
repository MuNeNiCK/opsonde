defmodule Opsonde.Targets.TargetPolicy do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "target_policies"
    repo Opsonde.Repo

    custom_indexes do
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :active_for_target do
      argument :target_id, :uuid, allow_nil?: false
      filter expr(target_id == ^arg(:target_id) and enabled == true and target.active == true)
      prepare build(sort: [id: :asc])
    end

    create :create do
      primary? true

      accept [
        :target_id,
        :name,
        :request_kinds,
        :capabilities,
        :operations,
        :selector_match,
        :parameter_match,
        :reason
      ]

      validate Opsonde.Targets.Validations.PolicyMatchers
      validate {Opsonde.Validations.BoundedMap, attribute: :selector_match}
      validate {Opsonde.Validations.BoundedMap, attribute: :parameter_match}
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :request_kinds,
        :capabilities,
        :operations,
        :selector_match,
        :parameter_match,
        :reason
      ]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.Validations.PolicyMatchers
      validate {Opsonde.Validations.BoundedMap, attribute: :selector_match}
      validate {Opsonde.Validations.BoundedMap, attribute: :parameter_match}
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change set_attribute(:enabled, false)
      change optimistic_lock(:revision)
    end

    action :clear_request, :struct do
      constraints instance_of: Opsonde.Targets.RequestClearance
      transaction? false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Opsonde.Targets.PolicyRequest]

      run {Opsonde.Targets.TargetPolicy.Actions.Request, operation: :clear}
    end

    action :dispatch_observation, :struct do
      constraints instance_of: Opsonde.Providers.Target.Observation
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Opsonde.Targets.RequestClearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Opsonde.Targets.TargetPolicy.Actions.Request, operation: :observe}
    end

    action :dispatch_effect, :struct do
      public? false
      constraints instance_of: Opsonde.Providers.Target.EffectResult
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Opsonde.Targets.RequestClearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Opsonde.Targets.TargetPolicy.Actions.Request, operation: :effect}
    end

    action :dispatch_verification, :struct do
      constraints instance_of: Opsonde.Providers.Target.Verification
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Opsonde.Targets.RequestClearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Opsonde.Targets.TargetPolicy.Actions.Request, operation: :verify}
    end
  end

  policies do
    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:active_for_target) do
      forbid_if always()
    end

    policy action([
             :clear_request,
             :dispatch_observation,
             :dispatch_verification
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action(:dispatch_effect) do
      forbid_if always()
    end

    policy action([:read, :page]) do
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

    attribute :request_kinds, {:array, :atom} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 2, items: [one_of: [:observation, :effect]]
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
      constraints max_length: 100, items: [min_length: 1, max_length: 120]
    end

    attribute :operations, {:array, :string} do
      allow_nil? false
      public? true
      default []
      constraints max_length: 100, items: [min_length: 1, max_length: 120]
    end

    attribute :selector_match, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :parameter_match, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :enabled, :boolean do
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
    belongs_to :target, Opsonde.Targets.Target do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_target_name, [:target_id, :name]
  end
end
