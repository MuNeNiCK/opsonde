defmodule Opsonde.Targets.Profiles.DellIDRAC.Redfish do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Targets.Adapters.Redfish

  @impl Opsonde.Providers.Adapter
  def type, do: "dell-idrac-redfish"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  defdelegate access_method_profile(), to: Redfish

  @impl Opsonde.Providers.Adapter
  defdelegate build(configuration, credentials), to: Redfish

  @impl Opsonde.Providers.Adapter
  defdelegate check(state, input), to: Redfish

  @impl Opsonde.Providers.Target
  defdelegate capabilities(state, invocation), to: Redfish

  @impl Opsonde.Providers.Target
  defdelegate classify_request(state, request), to: Redfish

  @impl Opsonde.Providers.Target
  defdelegate observe(state, request, invocation), to: Redfish

  @impl Opsonde.Providers.Target
  defdelegate effect(state, request, invocation), to: Redfish

  @impl Opsonde.Providers.Target
  defdelegate verify(state, request, invocation), to: Redfish
end
