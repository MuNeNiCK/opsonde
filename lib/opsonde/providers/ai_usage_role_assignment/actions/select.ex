defmodule Opsonde.Providers.AIUsageRoleAssignment.Actions.Select do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.AI

  @impl true
  def run(input, opts, _context) do
    role = opts[:role]

    case Providers.eligible_ai_usage_role_assignments(role, authorize?: false) do
      {:ok, [assignment | _rest]} ->
        {:ok, assigned_selection(assignment, role)}

      {:ok, []} when role == :reviewer ->
        fallback_to_resolver(input.arguments)

      {:ok, []} ->
        {:error, ai_error("No eligible Resolver AI is assigned")}

      {:error, _error} ->
        {:error, ai_error("AI usage role selection failed")}
    end
  end

  defp assigned_selection(assignment, role) do
    %AI.Selection{
      role: role,
      provider_id: assignment.provider_id,
      provider_revision: assignment.provider.revision,
      source: :assignment,
      assignment_id: assignment.id,
      assignment_revision: assignment.revision
    }
  end

  defp fallback_to_resolver(arguments) do
    with {:ok, assignment} <-
           Providers.load_resolver_ai_usage_role_assignment(
             arguments.resolver_assignment_id,
             arguments.resolver_assignment_revision,
             arguments.resolver_provider_revision,
             authorize?: false
           ) do
      {:ok,
       %AI.Selection{
         role: :reviewer,
         provider_id: assignment.provider_id,
         provider_revision: assignment.provider.revision,
         source: :resolver_fallback,
         assignment_id: assignment.id,
         assignment_revision: assignment.revision
       }}
    else
      {:error, _error} -> {:error, ai_error("Resolver AI is not eligible for review fallback")}
    end
  end

  defp ai_error(message), do: AI.Error.exception(category: :unavailable, message: message)
end
