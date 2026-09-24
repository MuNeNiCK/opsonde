defmodule Opsonde.Providers.AIUsageRoleAssignment.Actions.Select do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.AI

  @impl true
  def run(input, opts, _context) do
    role = opts[:role]
    excluded = Map.get(input.arguments, :excluded_provider_ids, []) |> MapSet.new()

    case Providers.eligible_ai_usage_role_assignments(role, authorize?: false) do
      {:ok, assignments} ->
        case Enum.find(assignments, &(not MapSet.member?(excluded, &1.provider_id))) do
          nil when role == :reviewer -> fallback_to_resolver(input.arguments, excluded)
          nil -> {:error, ai_error("No eligible Resolver AI is assigned")}
          assignment -> {:ok, assigned_selection(assignment, role)}
        end

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

  defp fallback_to_resolver(arguments, excluded) do
    with {:ok, assignment} <-
           Providers.load_resolver_ai_usage_role_assignment(
             arguments.resolver_assignment_id,
             arguments.resolver_assignment_revision,
             arguments.resolver_provider_revision,
             authorize?: false
           ),
         false <- MapSet.member?(excluded, assignment.provider_id) do
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
      _unavailable -> {:error, ai_error("Resolver AI is not eligible for review fallback")}
    end
  end

  defp ai_error(message), do: AI.Error.exception(category: :unavailable, message: message)
end
