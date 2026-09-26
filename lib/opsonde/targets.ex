defmodule Opsonde.Targets do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Targets.ManagementBoundary do
      define :list_management_boundaries, action: :read
      define :page_management_boundaries, action: :page
      define :get_management_boundary, action: :read, get_by: [:id]
      define :create_management_boundary, action: :create, args: [:name, :kind, :facts]
      define :update_management_boundary, action: :update, args: [:expected_revision]
      define :deactivate_management_boundary, action: :deactivate, args: [:expected_revision]
    end

    resource Opsonde.Targets.Target do
      define :list_targets, action: :read
      define :page_targets, action: :page
      define :get_target, action: :read, get_by: [:id]

      define :create_target,
        action: :create,
        args: [:name, :kind, :platform, :facts, :management_boundary_id]

      define :update_target, action: :update, args: [:expected_revision]
      define :deactivate_target, action: :deactivate, args: [:expected_revision]
      define :search_targets, action: :search, args: [:query, :max_results]
    end

    resource Opsonde.Targets.ExternalIdentity do
      define :list_external_identities, action: :read
      define :page_external_identities, action: :page
      define :get_external_identity, action: :read, get_by: [:id]
      define :external_identities_for_source, action: :for_source, args: [:source]

      define :resolve_external_identity,
        action: :resolve,
        args: [:source, :kind, :value]

      define :create_external_identity,
        action: :create,
        args: [:target_id, :source, :kind, :value]

      define :update_external_identity, action: :update, args: [:expected_revision]
      define :deactivate_external_identity, action: :deactivate, args: [:expected_revision]
    end

    resource Opsonde.Targets.AccessMethod do
      define :list_access_methods, action: :read
      define :page_access_methods, action: :page
      define :get_access_method, action: :read, get_by: [:id]

      define :available_access_methods_for_target,
        action: :available_for_target,
        args: [:target_id]

      define :create_access_method,
        action: :create,
        args: [
          :target_id,
          :provider_id,
          :name,
          :platform,
          :method,
          :endpoint,
          :provider_revision,
          :priority,
          :capabilities
        ]

      define :update_access_method, action: :update, args: [:expected_revision]
      define :deactivate_access_method, action: :deactivate, args: [:expected_revision]

      define :available_access_methods,
        action: :available,
        args: [:target_id, :capability]

      define :load_access_method_for_use,
        action: :for_use,
        args: [:id, :expected_revision, :capability]
    end

    resource Opsonde.Targets.Relationship do
      define :list_relationships, action: :read
      define :page_relationships, action: :page
      define :get_relationship, action: :read, get_by: [:id]

      define :create_relationship,
        action: :create,
        args: [:source_target_id, :destination_target_id, :kind, :facts, :valid_until]

      define :update_relationship, action: :update, args: [:expected_revision]
      define :deactivate_relationship, action: :deactivate, args: [:expected_revision]

      define :load_relationship_for_traversal,
        action: :for_traversal,
        args: [:id, :expected_revision]

      define :adjacent_relationships_for_traversal,
        action: :adjacent_for_traversal,
        args: [:target_id]
    end

    resource Opsonde.Targets.TargetPolicy do
      define :list_target_policies, action: :read
      define :page_target_policies, action: :page
      define :get_target_policy, action: :read, get_by: [:id]

      define :active_target_policies,
        action: :active_for_target,
        args: [:target_id]

      define :create_target_policy,
        action: :create,
        args: [
          :target_id,
          :name,
          :request_kinds,
          :capabilities,
          :operations,
          :selector_match,
          :parameter_match,
          :reason
        ]

      define :update_target_policy, action: :update, args: [:expected_revision]
      define :deactivate_target_policy, action: :deactivate, args: [:expected_revision]
      define :clear_target_request, action: :clear_request, args: [:request]

      define :dispatch_target_observation,
        action: :dispatch_observation,
        args: [:clearance, :invocation]

      define :dispatch_target_effect,
        action: :dispatch_effect,
        args: [:clearance, :invocation]

      define :dispatch_target_verification,
        action: :dispatch_verification,
        args: [:clearance, :invocation]
    end

    resource Opsonde.Targets.InventoryImport do
      define :list_inventory_imports, action: :read
      define :page_inventory_imports, action: :page
      define :get_inventory_import, action: :read, get_by: [:id]
      define :create_inventory_import_preview, action: :create_preview

      define :mark_inventory_import_applied,
        action: :mark_applied,
        args: [:expected_revision]

      define :preview_manual_inventory,
        action: :preview_manual,
        args: [:source, :csv]

      define :preview_provider_inventory,
        action: :preview_inventory,
        args: [:source, :provider_id, :request, :invocation]

      define :apply_inventory_import,
        action: :apply,
        args: [:id, :expected_revision, :expected_digest]
    end

    resource Opsonde.Targets.InventoryImportRow do
      define :list_inventory_import_rows, action: :read

      define :page_inventory_import_rows,
        action: :page_for_import,
        args: [:inventory_import_id]

      define :inventory_import_rows,
        action: :for_import,
        args: [:inventory_import_id]

      define :create_inventory_import_row, action: :create
    end

    resource Opsonde.Targets.BMCOperation do
      define :list_bmc_operations, action: :read
      define :get_bmc_operation, action: :read, get_by: [:id]

      define :available_bmc_operations_for_method,
        action: :available_for_method,
        args: [:access_method_id]

      define :load_bmc_operation_for_use,
        action: :for_use,
        args: [:id, :expected_revision, :access_method_id]

      define :create_bmc_operation,
        action: :create,
        args: [
          :access_method_id,
          :name,
          :description,
          :request_kind,
          :protocol_request,
          :input_schema,
          :output_schema,
          :verification_schema
        ]

      define :update_bmc_operation, action: :update, args: [:expected_revision]
      define :deactivate_bmc_operation, action: :deactivate, args: [:expected_revision]
    end
  end
end
