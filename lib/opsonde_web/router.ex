defmodule OpsondeWeb.Router do
  use OpsondeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug OpsondeWeb.API.Auth
  end

  scope "/api/v1", OpsondeWeb.API.V1 do
    pipe_through :api

    post "/accounts/bootstrap", AccountController, :bootstrap
    post "/sessions", SessionController, :create
  end

  scope "/api/v1", OpsondeWeb.API.V1 do
    pipe_through [:api, :authenticated_api]

    get "/session", SessionController, :show
    delete "/session", SessionController, :delete
    get "/accounts", AccountController, :index
    post "/accounts", AccountController, :create
    patch "/accounts/:id/role", AccountController, :update_role

    get "/providers", ProviderController, :index
    post "/providers", ProviderController, :create
    get "/providers/:id", ProviderController, :show
    patch "/providers/:id", ProviderController, :update
    post "/providers/:id/check", ProviderController, :check
    post "/providers/:id/target-capabilities", ProviderController, :target_capabilities
    post "/providers/:id/enable", ProviderController, :enable
    post "/providers/:id/disable", ProviderController, :disable

    get "/ai-usage-role-assignments", AIUsageRoleAssignmentController, :index
    post "/ai-usage-role-assignments", AIUsageRoleAssignmentController, :create
    patch "/ai-usage-role-assignments/:id", AIUsageRoleAssignmentController, :update

    get "/management-boundaries", TargetSetupController, :boundaries_index
    post "/management-boundaries", TargetSetupController, :boundaries_create
    patch "/management-boundaries/:id", TargetSetupController, :boundaries_update
    post "/management-boundaries/:id/deactivate", TargetSetupController, :boundaries_deactivate

    get "/targets", TargetSetupController, :targets_index
    post "/targets", TargetSetupController, :targets_create
    get "/targets/:id", TargetSetupController, :targets_show
    patch "/targets/:id", TargetSetupController, :targets_update
    post "/targets/:id/deactivate", TargetSetupController, :targets_deactivate

    get "/external-identities", TargetSetupController, :identities_index
    post "/external-identities", TargetSetupController, :identities_create
    patch "/external-identities/:id", TargetSetupController, :identities_update
    post "/external-identities/:id/deactivate", TargetSetupController, :identities_deactivate

    get "/access-methods", TargetSetupController, :access_methods_index
    post "/access-methods", TargetSetupController, :access_methods_create
    patch "/access-methods/:id", TargetSetupController, :access_methods_update
    post "/access-methods/:id/deactivate", TargetSetupController, :access_methods_deactivate

    get "/target-relationships", TargetSetupController, :relationships_index
    post "/target-relationships", TargetSetupController, :relationships_create
    patch "/target-relationships/:id", TargetSetupController, :relationships_update
    post "/target-relationships/:id/deactivate", TargetSetupController, :relationships_deactivate

    get "/target-policies", TargetSetupController, :policies_index
    post "/target-policies", TargetSetupController, :policies_create
    patch "/target-policies/:id", TargetSetupController, :policies_update
    post "/target-policies/:id/deactivate", TargetSetupController, :policies_deactivate

    get "/inventory-imports", InventoryImportController, :index
    post "/inventory-imports/manual-preview", InventoryImportController, :preview_manual
    post "/inventory-imports/provider-preview", InventoryImportController, :preview_provider
    get "/inventory-imports/:id", InventoryImportController, :show
    get "/inventory-imports/:id/rows", InventoryImportController, :rows
    post "/inventory-imports/:id/apply", InventoryImportController, :apply_import

    get "/authority-settings", AuthoritySettingController, :index
    get "/authority-setting", AuthoritySettingController, :show
    put "/authority-setting", AuthoritySettingController, :update

    get "/cases", CaseController, :index
    post "/cases", CaseController, :create
    get "/cases/:id", CaseController, :show
    get "/cases/:id/timeline", CaseController, :timeline
    get "/cases/:id/turns", CaseController, :turns
    get "/cases/:id/evidence", CaseController, :evidence
    get "/cases/:id/approvals", CaseController, :approvals
    get "/cases/:id/review-decisions", CaseController, :review_decisions
    post "/cases/:id/claim", CaseController, :claim
    post "/cases/:id/handoff", CaseController, :handoff
    post "/cases/:id/cancel", CaseController, :cancel
    post "/cases/:id/resume", CaseController, :resume

    get "/proposals/:id", ProposalController, :show
    post "/proposals/:id/decision", ProposalController, :decide
    get "/operations/:id", OperationController, :show
    get "/verification-attempts/:id", OperationController, :show_verification

    get "/signal-receipts", SignalReceiptController, :index
    get "/signal-receipts/:id", SignalReceiptController, :show

    get "/audit-schedules", AuditController, :schedules
    post "/audit-schedules", AuditController, :schedule
    get "/audit-schedules/:id", AuditController, :show_schedule
    post "/audit-schedules/:id/deactivate", AuditController, :deactivate
    get "/audit-runs", AuditController, :runs
    get "/audit-runs/:id", AuditController, :show_run

    get "/reports", ReportController, :index
    get "/reports/:id", ReportController, :show
    post "/cases/:case_id/reports", ReportController, :generate

    get "/deliveries", DeliveryController, :index
    post "/deliveries", DeliveryController, :create
    get "/deliveries/:id", DeliveryController, :show
  end

  scope "/api/v1", OpsondeWeb do
    pipe_through :api

    post "/signals/alertmanager/:provider_id", SignalWebhookController, :alertmanager
    post "/signals/zabbix/:provider_id", SignalWebhookController, :zabbix
  end

  scope "/api/v1", OpsondeWeb do
    pipe_through :api

    match :*, "/*path", APIErrorController, :not_found
  end

  scope "/", OpsondeWeb do
    get "/*path", SPAController, :index
  end
end
