defmodule Opsonde.OIDCTest do
  use Opsonde.DataCase, async: false

  alias AshAuthentication.Strategy
  alias Opsonde.Accounts
  alias Opsonde.Accounts.{OIDCProvider, OIDCRequest, User, UserIdentity}

  @password "correct horse battery staple"

  test "an unknown OIDC subject cannot create or select a local account" do
    admin = bootstrap_admin!()
    params = oidc_params("unknown-subject")
    strategy = AshAuthentication.Info.strategy!(User, :oidc)

    assert {:error, _error} = Strategy.action(strategy, :sign_in, params, authorize?: true)
    assert Ash.count!(User, authorize?: false) == 1
    assert Ash.count!(UserIdentity, authorize?: false) == 0
    assert to_string(admin.email) == "oidc-admin@example.com"
  end

  test "a local account explicitly links one issuer subject and later signs in" do
    admin = bootstrap_admin!()
    start_token = OIDCRequest.random_secret()

    request =
      Accounts.create_oidc_link!(
        admin.id,
        OIDCRequest.digest(start_token),
        DateTime.add(DateTime.utc_now(), 600, :second),
        authorize?: false
      )

    request =
      Accounts.start_oidc_request!(request, request.revision, start_token, authorize?: false)

    strategy = AshAuthentication.Info.strategy!(User, :oidc)

    params =
      "linked-subject"
      |> oidc_params()
      |> put_in(["user_info", "email"], "different-identity@example.com")
      |> put_in(["user_info", "email_verified"], false)

    actor = Ash.Resource.set_metadata(admin, %{oidc_link_request_id: request.id})

    assert {:ok, linked} =
             Strategy.action(strategy, :sign_in, params,
               actor: actor,
               authorize?: true
             )

    assert linked.id == admin.id
    assert is_binary(Ash.Resource.get_metadata(linked, :token))

    completed_request = Accounts.get_oidc_request!(request.id, authorize?: false)
    assert completed_request.completed_at
    assert completed_request.user_id == admin.id

    [identity] = Ash.read!(UserIdentity, authorize?: false)
    assert identity.user_id == admin.id
    assert identity.strategy == "oidc"
    assert identity.uid == "linked-subject"

    refreshed_params =
      put_in(params, ["oauth_tokens"], %{
        "access_token" => "refreshed-access-token",
        "refresh_token" => "refreshed-refresh-token",
        "expires_in" => 600
      })

    assert {:ok, signed_in} =
             Strategy.action(strategy, :sign_in, refreshed_params, authorize?: true)

    assert signed_in.id == admin.id
    assert is_binary(Ash.Resource.get_metadata(signed_in, :token))

    refreshed_identity = Ash.get!(UserIdentity, identity.id, authorize?: false)
    assert refreshed_identity.access_token == "refreshed-access-token"
    assert refreshed_identity.refresh_token == "refreshed-refresh-token"
    assert DateTime.after?(refreshed_identity.access_token_expires_at, DateTime.utc_now())

    second_start_token = OIDCRequest.random_secret()

    second_request =
      Accounts.create_oidc_link!(
        admin.id,
        OIDCRequest.digest(second_start_token),
        DateTime.add(DateTime.utc_now(), 600, :second),
        authorize?: false
      )

    second_request =
      Accounts.start_oidc_request!(
        second_request,
        second_request.revision,
        second_start_token,
        authorize?: false
      )

    second_actor = Ash.Resource.set_metadata(admin, %{oidc_link_request_id: second_request.id})

    assert {:error, _error} =
             Strategy.action(strategy, :sign_in, oidc_params("another-subject"),
               actor: second_actor,
               authorize?: true
             )

    assert Ash.count!(UserIdentity, authorize?: false) == 1
    refute Accounts.get_oidc_request!(second_request.id, authorize?: false).completed_at
  end

  test "OIDC provider secret is encrypted and issuer identity becomes immutable after linking" do
    admin = bootstrap_admin!()

    provider =
      Accounts.configure_oidc!(
        %{
          issuer: "https://identity.example.test/realms/opsonde/",
          client_id: "opsonde",
          client_secret: "provider-secret",
          enabled: true
        },
        actor: admin
      )

    assert provider.issuer == "https://identity.example.test/realms/opsonde"

    encrypted =
      Opsonde.Repo.query!("select encrypted_client_secret from oidc_providers where id = $1", [
        Ecto.UUID.dump!(provider.id)
      ]).rows
      |> hd()
      |> hd()

    assert is_binary(encrypted)
    refute encrypted =~ "provider-secret"

    Ash.create!(
      UserIdentity,
      %{
        user_info: %{"sub" => "subject"},
        oauth_tokens: %{},
        strategy: :oidc,
        user_id: admin.id
      },
      action: :upsert,
      authorize?: false
    )

    assert {:error, _error} =
             Accounts.configure_oidc(
               %{
                 issuer: "https://replacement.example.test",
                 client_id: "replacement",
                 client_secret: "replacement-secret",
                 enabled: true
               },
               actor: admin
             )

    assert Accounts.current_oidc_provider!(authorize?: false).id == provider.id
    assert Ash.count!(OIDCProvider, authorize?: false) == 1
  end

  test "CLI exchange request is short-lived, verifier-bound and single-use" do
    verifier = OIDCRequest.random_secret()
    start_token = OIDCRequest.random_secret()
    code = OIDCRequest.random_secret()
    user = bootstrap_admin!()

    request =
      Accounts.create_cli_login!(
        OIDCRequest.digest(start_token),
        OIDCRequest.digest(verifier),
        "http://127.0.0.1:54321/callback",
        DateTime.add(DateTime.utc_now(), 600, :second),
        authorize?: false
      )

    request = Accounts.start_oidc_request!(request, 1, start_token, authorize?: false)

    request =
      Accounts.complete_oidc_request!(
        request,
        request.revision,
        user.id,
        OIDCRequest.digest(code),
        authorize?: false
      )

    assert {:error, _error} =
             Accounts.consume_oidc_request(
               request,
               request.revision,
               code,
               "wrong-verifier",
               authorize?: false
             )

    consumed =
      Accounts.consume_oidc_request!(
        request,
        request.revision,
        code,
        verifier,
        authorize?: false
      )

    assert consumed.consumed_at

    assert {:error, _error} =
             Accounts.consume_oidc_request(
               consumed,
               consumed.revision,
               code,
               verifier,
               authorize?: false
             )
  end

  defp bootstrap_admin! do
    Accounts.bootstrap!(
      "oidc-admin@example.com",
      @password,
      @password,
      authorize?: true
    )
  end

  defp oidc_params(subject) do
    %{
      "user_info" => %{
        "iss" => "https://identity.example.test/realms/opsonde",
        "sub" => subject,
        "email" => "oidc-admin@example.com",
        "email_verified" => true
      },
      "oauth_tokens" => %{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 300
      }
    }
  end
end
