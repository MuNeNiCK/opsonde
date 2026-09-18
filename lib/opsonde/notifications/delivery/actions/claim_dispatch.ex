defmodule Opsonde.Notifications.Delivery.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.Notifications
  alias Opsonde.Notifications.{Delivery, DeliveryClaim}

  @terminal [:accepted, :delivered, :failed, :unknown]

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Delivery], fn ->
      with {:ok, delivery} <- lock(input.arguments.id) do
        claim(delivery)
      end
    end)
  end

  defp claim(%Delivery{status: :queued} = delivery) do
    with {:ok, claimed} <-
           Notifications.mark_delivery_dispatching(
             delivery,
             delivery.revision,
             %{dispatch_started_at: DateTime.utc_now()},
             authorize?: false
           ) do
      %DeliveryClaim{state: :claimed, delivery: claimed}
    end
  end

  defp claim(%Delivery{status: :dispatching} = delivery) do
    with {:ok, terminal} <-
           Notifications.record_delivery_outcome(
             delivery,
             delivery.revision,
             %{
               status: :unknown,
               details: %{
                 "message" => "Delivery ownership was lost after the durable send marker"
               },
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      %DeliveryClaim{state: :terminal, delivery: terminal}
    end
  end

  defp claim(%Delivery{status: status} = delivery) when status in @terminal,
    do: %DeliveryClaim{state: :terminal, delivery: delivery}

  defp lock(id) do
    Delivery
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Notification Delivery is unavailable"}
      result -> result
    end
  end
end
