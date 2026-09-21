defmodule Opsonde.Cases.Realtime do
  @moduledoc false

  @pubsub Opsonde.PubSub
  @topic_prefix "case_changes:"

  def subscribe(case_id) when is_binary(case_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(case_id))
  end

  def publish(case_id) when is_binary(case_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(case_id), {:case_changed, case_id})
  end

  defp topic(case_id), do: @topic_prefix <> case_id
end
