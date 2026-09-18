defmodule Opsonde.ProvidersTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.Providers

  import ExUnit.CaptureLog

  @password "correct horse battery staple"
  @token "private-provider-token"

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)

    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "Ash interface stores only ciphertext and enforces lifecycle policy", context do
    provider = create_provider!(context.admin, "reachable")

    assert provider.revision == 1
    assert provider.role == :target
    refute provider.enabled
    assert %Ash.NotLoaded{} = provider.credentials
    assert is_binary(provider.encrypted_credentials)
    refute provider.encrypted_credentials =~ @token
    refute inspect(provider) =~ @token

    assert [listed] = Providers.list_providers!(actor: context.operator)
    assert listed.id == provider.id
    assert [listed_for_viewer] = Providers.list_providers!(actor: context.viewer)
    assert listed_for_viewer.id == provider.id

    protected =
      Providers.get_provider!(provider.id,
        actor: context.operator,
        load: [:credentials]
      )

    assert %Ash.ForbiddenField{} = protected.credentials

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.create_provider(
               "forbidden",
               :target,
               "fixture-target",
               %{"endpoint" => "reachable"},
               %{"token" => @token},
               actor: context.operator
             )

    assert {:error, error} =
             Providers.create_provider(
               "wrong-role",
               :inventory,
               "fixture-target",
               %{"endpoint" => "reachable"},
               %{"token" => @token},
               actor: context.admin
             )

    assert Exception.message(error) =~ "does not match"
    refute inspect(error) =~ @token

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.record_provider_check(
               provider,
               1,
               :passed,
               nil,
               nil,
               actor: context.admin
             )
  end

  test "check, enable, edit, and disable use the current revision", context do
    provider = create_provider!(context.admin, "reachable")

    checked = Providers.check_provider!(provider.id, 1, %{}, actor: context.admin)
    assert checked.check_status == :passed
    assert checked.checked_revision == 1
    assert %Ash.NotLoaded{} = checked.credentials

    enabled = Providers.enable_provider!(checked, 1, actor: context.admin)
    assert enabled.enabled

    failed_recheck =
      Providers.check_provider!(enabled.id, 1, %{"fail" => true}, actor: context.admin)

    refute failed_recheck.enabled
    assert failed_recheck.check_category == :unreachable

    edited =
      Providers.update_provider!(
        failed_recheck,
        1,
        %{name: "renamed", configuration: %{"endpoint" => "reachable"}},
        actor: context.admin
      )

    assert edited.revision == 2
    refute edited.enabled
    assert is_nil(edited.checked_revision)
    assert is_nil(edited.check_status)
    assert {:error, _error} = Providers.enable_provider(edited, 2, actor: context.admin)

    checked_again = Providers.check_provider!(edited.id, 2, %{}, actor: context.admin)
    enabled_again = Providers.enable_provider!(checked_again, 2, actor: context.admin)
    disabled = Providers.disable_provider!(enabled_again, 2, actor: context.admin)
    refute disabled.enabled
  end

  test "connection failures remain distinct and persisted messages redact secrets", context do
    for category <- ~w(authentication unreachable capability) do
      provider = create_provider!(context.admin, category, category)
      checked = Providers.check_provider!(provider.id, 1, %{}, actor: context.admin)

      assert checked.check_status == :failed
      assert checked.check_category == String.to_existing_atom(category)
      assert checked.check_message == "fixture #{category}"
    end

    invalid_configuration =
      Providers.create_provider!(
        "invalid-configuration",
        :target,
        "fixture-target",
        %{},
        %{"token" => @token},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))

    assert invalid_configuration.check_category == :invalid_configuration

    provider_failure = create_provider!(context.admin, "invalid_response", "provider-failure")

    assert Providers.check_provider!(provider_failure.id, 1, %{}, actor: context.admin).check_category ==
             :provider_failure

    log =
      capture_log([level: :debug], fn ->
        redacted = create_provider!(context.admin, "echo", "redaction")
        checked = Providers.check_provider!(redacted.id, 1, %{}, actor: context.admin)
        send(self(), {:redacted_check, checked})
      end)

    assert_receive {:redacted_check, checked}

    assert checked.check_category == :authentication
    assert checked.check_message == "credential [REDACTED] was rejected"
    refute inspect(checked) =~ @token
    refute log =~ @token
  end

  test "a stale check result cannot overwrite a newer Provider revision", context do
    provider = create_provider!(context.admin, "reachable")

    edited =
      Providers.update_provider!(
        provider,
        1,
        %{configuration: %{"endpoint" => "reachable"}},
        actor: context.admin
      )

    assert {:error, %Ash.Error.Invalid{} = error} =
             Providers.record_provider_check(
               provider,
               1,
               :passed,
               nil,
               nil,
               actor: context.admin,
               authorize?: false
             )

    assert Exception.message(error) =~ "is stale"
    refute inspect(error) =~ @token
    assert edited.revision == 2

    current = Providers.get_provider!(provider.id, actor: context.admin)
    assert current.revision == 2
    assert is_nil(current.checked_revision)
  end

  defp create_provider!(admin, endpoint, name \\ "primary") do
    Providers.create_provider!(
      name,
      :target,
      "fixture-target",
      %{"endpoint" => endpoint},
      %{"token" => @token},
      actor: admin
    )
  end
end
