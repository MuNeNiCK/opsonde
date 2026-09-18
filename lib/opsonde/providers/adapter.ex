defmodule Opsonde.Providers.Adapter do
  @moduledoc false

  @type role :: :ai | :signal | :target | :inventory | :notification
  @type check_failure :: :invalid_configuration | :authentication | :unreachable | :capability

  @callback type() :: String.t()
  @callback role() :: role()
  @callback build(configuration :: map(), credentials :: map()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback check(state :: term(), input :: map()) ::
              :ok | {:error, check_failure(), String.t()}
end
