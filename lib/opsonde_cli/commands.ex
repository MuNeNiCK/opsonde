defmodule OpsondeCLI.Commands do
  @moduledoc false

  defmodule Route do
    @moduledoc false
    defstruct [:method, :path, :ids, :root, :outcome, auth?: true, page?: false]

    def new(method, path, ids \\ 0, root \\ nil, options \\ []) do
      struct!(
        __MODULE__,
        Keyword.merge([method: method, path: path, ids: ids, root: root], options)
      )
    end

    def page(path, ids \\ 0),
      do: %__MODULE__{method: :get, path: path, ids: ids, page?: true}
  end

  alias __MODULE__.Route

  @routes %{
    {"auth", "status"} => Route.new(:get, "/session"),
    {"auth", "logout"} => Route.new(:delete, "/session"),
    {"account", "list"} => Route.page("/accounts"),
    {"account", "create"} => Route.new(:post, "/accounts", 0, "account"),
    {"account", "change-role"} => Route.new(:patch, "/accounts/:id/role", 1, "account"),
    {"provider", "list"} => Route.page("/providers"),
    {"provider", "show"} => Route.new(:get, "/providers/:id", 1),
    {"provider", "create"} => Route.new(:post, "/providers", 0, "provider"),
    {"provider", "update"} => Route.new(:patch, "/providers/:id", 1, "provider"),
    {"provider", "check"} => Route.new(:post, "/providers/:id/check", 1, "provider"),
    {"provider", "capabilities"} =>
      Route.new(:post, "/providers/:id/target-capabilities", 1, "provider"),
    {"provider", "enable"} => Route.new(:post, "/providers/:id/enable", 1, "provider"),
    {"provider", "disable"} => Route.new(:post, "/providers/:id/disable", 1, "provider"),
    {"ai-role", "list"} => Route.page("/ai-usage-role-assignments"),
    {"ai-role", "create"} => Route.new(:post, "/ai-usage-role-assignments", 0, "assignment"),
    {"ai-role", "update"} => Route.new(:patch, "/ai-usage-role-assignments/:id", 1, "assignment"),
    {"boundary", "list"} => Route.page("/management-boundaries"),
    {"boundary", "create"} =>
      Route.new(:post, "/management-boundaries", 0, "management_boundary"),
    {"boundary", "update"} =>
      Route.new(:patch, "/management-boundaries/:id", 1, "management_boundary"),
    {"boundary", "deactivate"} =>
      Route.new(:post, "/management-boundaries/:id/deactivate", 1, "management_boundary"),
    {"target", "list"} => Route.page("/targets"),
    {"target", "show"} => Route.new(:get, "/targets/:id", 1),
    {"target", "create"} => Route.new(:post, "/targets", 0, "target"),
    {"target", "update"} => Route.new(:patch, "/targets/:id", 1, "target"),
    {"target", "deactivate"} => Route.new(:post, "/targets/:id/deactivate", 1, "target"),
    {"identity", "list"} => Route.page("/external-identities"),
    {"identity", "create"} => Route.new(:post, "/external-identities", 0, "external_identity"),
    {"identity", "update"} =>
      Route.new(:patch, "/external-identities/:id", 1, "external_identity"),
    {"identity", "deactivate"} =>
      Route.new(:post, "/external-identities/:id/deactivate", 1, "external_identity"),
    {"access-method", "list"} => Route.page("/access-methods"),
    {"access-method", "create"} => Route.new(:post, "/access-methods", 0, "access_method"),
    {"access-method", "update"} => Route.new(:patch, "/access-methods/:id", 1, "access_method"),
    {"access-method", "deactivate"} =>
      Route.new(:post, "/access-methods/:id/deactivate", 1, "access_method"),
    {"relationship", "list"} => Route.page("/target-relationships"),
    {"relationship", "create"} => Route.new(:post, "/target-relationships", 0, "relationship"),
    {"relationship", "update"} =>
      Route.new(:patch, "/target-relationships/:id", 1, "relationship"),
    {"relationship", "deactivate"} =>
      Route.new(:post, "/target-relationships/:id/deactivate", 1, "relationship"),
    {"policy", "list"} => Route.page("/target-policies"),
    {"policy", "create"} => Route.new(:post, "/target-policies", 0, "target_policy"),
    {"policy", "update"} => Route.new(:patch, "/target-policies/:id", 1, "target_policy"),
    {"policy", "deactivate"} =>
      Route.new(:post, "/target-policies/:id/deactivate", 1, "target_policy"),
    {"inventory", "list"} => Route.page("/inventory-imports"),
    {"inventory", "show"} => Route.new(:get, "/inventory-imports/:id", 1),
    {"inventory", "rows"} => Route.page("/inventory-imports/:id/rows", 1),
    {"inventory", "preview-manual"} =>
      Route.new(:post, "/inventory-imports/manual-preview", 0, "inventory_import"),
    {"inventory", "preview-provider"} =>
      Route.new(:post, "/inventory-imports/provider-preview", 0, "inventory_import"),
    {"inventory", "apply"} =>
      Route.new(:post, "/inventory-imports/:id/apply", 1, "inventory_import"),
    {"authority", "list"} => Route.page("/authority-settings"),
    {"authority", "show"} => Route.new(:get, "/authority-setting"),
    {"authority", "set"} => Route.new(:put, "/authority-setting", 0, "authority_setting"),
    {"case", "list"} => Route.page("/cases"),
    {"case", "show"} => Route.new(:get, "/cases/:id", 1, nil, outcome: :case),
    {"case", "create"} => Route.new(:post, "/cases", 0, "case", outcome: :case_record),
    {"case", "timeline"} => Route.page("/cases/:id/timeline", 1),
    {"case", "turns"} => Route.page("/cases/:id/turns", 1),
    {"case", "evidence"} => Route.page("/cases/:id/evidence", 1),
    {"case", "approvals"} => Route.page("/cases/:id/approvals", 1),
    {"case", "reviews"} => Route.page("/cases/:id/review-decisions", 1),
    {"case", "claim"} => Route.new(:post, "/cases/:id/claim", 1, "case", outcome: :case_record),
    {"case", "handoff"} =>
      Route.new(:post, "/cases/:id/handoff", 1, "case", outcome: :case_record),
    {"case", "cancel"} => Route.new(:post, "/cases/:id/cancel", 1, "case", outcome: :case_record),
    {"case", "resume"} => Route.new(:post, "/cases/:id/resume", 1, "case"),
    {"proposal", "show"} => Route.new(:get, "/proposals/:id", 1, nil, outcome: :proposal),
    {"proposal", "decide"} =>
      Route.new(:post, "/proposals/:id/decision", 1, "proposal", outcome: :proposal),
    {"operation", "show"} => Route.new(:get, "/operations/:id", 1, nil, outcome: :operation),
    {"verification", "show"} =>
      Route.new(:get, "/verification-attempts/:id", 1, nil, outcome: :verification),
    {"signal", "list"} => Route.page("/signal-receipts"),
    {"signal", "show"} => Route.new(:get, "/signal-receipts/:id", 1),
    {"signal", "events"} => Route.page("/signal-receipts/:id/events", 1),
    {"audit", "list"} => Route.page("/audit-schedules"),
    {"audit", "schedule"} => Route.new(:post, "/audit-schedules", 0, "audit_schedule"),
    {"audit", "show"} => Route.new(:get, "/audit-schedules/:id", 1),
    {"audit", "deactivate"} =>
      Route.new(:post, "/audit-schedules/:id/deactivate", 1, "audit_schedule"),
    {"audit-run", "list"} => Route.page("/audit-runs"),
    {"audit-run", "show"} => Route.new(:get, "/audit-runs/:id", 1),
    {"report", "list"} => Route.page("/reports"),
    {"report", "show"} => Route.new(:get, "/reports/:id", 1),
    {"report", "generate"} => Route.new(:post, "/cases/:id/reports", 1, "report"),
    {"delivery", "list"} => Route.page("/deliveries"),
    {"delivery", "show"} => Route.new(:get, "/deliveries/:id", 1, nil, outcome: :delivery),
    {"delivery", "create"} => Route.new(:post, "/deliveries", 0, "delivery", outcome: :delivery)
  }

  @wait_routes %{
    "case" => Map.fetch!(@routes, {"case", "show"}),
    "operation" => Map.fetch!(@routes, {"operation", "show"}),
    "verification" => Map.fetch!(@routes, {"verification", "show"}),
    "delivery" => Map.fetch!(@routes, {"delivery", "show"})
  }

  def lookup([resource, "wait", id | rest]) do
    case Map.fetch(@wait_routes, resource) do
      {:ok, route} -> {:ok, route, [id], rest, :wait}
      :error -> :error
    end
  end

  def lookup([resource, action | rest]) do
    with {:ok, route} <- Map.fetch(@routes, {resource, action}),
         true <- length(rest) >= route.ids do
      {ids, options} = Enum.split(rest, route.ids)
      {:ok, route, ids, options, :once}
    else
      _other -> :error
    end
  end

  def lookup(_args), do: :error

  def path(%Route{path: path}, ids) do
    Enum.reduce(ids, path, fn id, current ->
      String.replace(current, ":id", URI.encode_www_form(id), global: false)
    end)
  end
end
