defmodule Opsonde.Targets.Profiles.DellIDRAC.IPMI do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Targets.Adapters.IPMI

  @impl Opsonde.Providers.Adapter
  def type, do: "dell-idrac-ipmi"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  defdelegate access_method_profile(), to: IPMI

  @impl Opsonde.Providers.Adapter
  defdelegate build(configuration, credentials), to: IPMI

  @impl Opsonde.Providers.Adapter
  defdelegate check(state, input), to: IPMI

  @impl Opsonde.Providers.Target
  defdelegate capabilities(state, invocation), to: IPMI

  @impl Opsonde.Providers.Target
  defdelegate classify_request(state, request), to: IPMI

  @impl Opsonde.Providers.Target
  defdelegate observe(state, request, invocation), to: IPMI

  @impl Opsonde.Providers.Target
  defdelegate effect(state, request, invocation), to: IPMI

  @impl Opsonde.Providers.Target
  defdelegate verify(state, request, invocation), to: IPMI
end
