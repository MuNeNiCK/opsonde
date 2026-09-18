defmodule Opsonde.Providers do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Providers.Provider do
      define :list_providers, action: :read
      define :get_provider, action: :read, get_by: [:id]

      define :load_provider_for_invocation,
        action: :for_invocation,
        args: [:id, :expected_revision, :expected_role]

      define :create_provider,
        action: :create,
        args: [:name, :role, :adapter_type, :configuration, :credentials]

      define :update_provider, action: :update, args: [:expected_revision]
      define :check_provider, action: :check, args: [:id, :expected_revision, :input]

      define :target_capabilities,
        action: :target_capabilities,
        args: [:provider_id, :expected_revision, :invocation]

      define :target_observe,
        action: :target_observe,
        args: [:provider_id, :request, :invocation]

      define :target_effect,
        action: :target_effect,
        args: [:provider_id, :request, :invocation]

      define :target_verify,
        action: :target_verify,
        args: [:provider_id, :request, :invocation]

      define :signal_ingest,
        action: :signal_ingest,
        args: [:provider_id, :expected_revision, :envelope, :invocation]

      define :inventory_snapshot,
        action: :inventory_snapshot,
        args: [:provider_id, :request, :invocation]

      define :record_provider_check,
        action: :record_check,
        args: [:expected_revision, :check_status, :check_category, :check_message]

      define :enable_provider, action: :enable, args: [:expected_revision]
      define :disable_provider, action: :disable, args: [:expected_revision]
    end
  end
end
