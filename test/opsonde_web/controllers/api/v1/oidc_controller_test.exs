defmodule OpsondeWeb.API.V1.OIDCControllerTest do
  use OpsondeWeb.ConnCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.Accounts.OIDCRequest

  @password "correct horse battery staple"

  test "admin configures optional OIDC without exposing its secret" do
    token = bootstrap_and_sign_in!()

    assert %{
             "data" => %{
               "enabled" => false,
               "callback_uri" => "http://localhost:4000/auth/user/oidc/callback"
             }
           } =
             get_json("/api/v1/oidc/provider", token) |> json_response(200)

    configured =
      put_json(
        "/api/v1/oidc/provider",
        %{
          "oidc_provider" => %{
            "issuer" => "https://identity.example.test/realms/opsonde",
            "client_id" => "opsonde",
            "client_secret" => "do-not-return",
            "enabled" => true
          }
        },
        token
      )

    assert %{
             "data" => %{
               "issuer" => "https://identity.example.test/realms/opsonde",
               "client_id" => "opsonde",
               "enabled" => true
             }
           } = json_response(configured, 200)

    refute configured.resp_body =~ "do-not-return"

    assert %{
             "data" => %{
               "enabled" => true,
               "authorization_url" => authorization_url,
               "callback_uri" => callback_uri
             }
           } =
             get_json("/api/v1/oidc") |> json_response(200)

    assert authorization_url == "http://localhost:4000/auth/user/oidc"
    assert callback_uri == "http://localhost:4000/auth/user/oidc/callback"
  end

  test "a disabled provider cannot be reached through the direct browser route" do
    token = bootstrap_and_sign_in!()
    configure_oidc!(token, false)

    assert %{
             "data" => %{"enabled" => false, "authorization_url" => nil}
           } = get_json("/api/v1/oidc") |> json_response(200)

    response = get(build_conn(), "/auth/user/oidc")
    assert html_response(response, 200) =~ "opsonde:oidc-error"
  end

  test "CLI request accepts only loopback callbacks and exchanges one session once" do
    token = bootstrap_and_sign_in!()
    configure_oidc!(token)
    verifier = OIDCRequest.random_secret()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)

    invalid =
      post_json("/api/v1/oidc/cli/requests", %{
        "request" => %{
          "redirect_uri" => "https://attacker.example/callback",
          "code_challenge" => challenge
        }
      })

    assert %{"error" => %{"code" => "bad_request"}} = json_response(invalid, 400)

    created =
      post_json("/api/v1/oidc/cli/requests", %{
        "request" => %{
          "redirect_uri" => "http://127.0.0.1:54321/callback",
          "code_challenge" => challenge
        }
      })

    %{"data" => %{"id" => id, "authorization_url" => authorization_url}} =
      json_response(created, 201)

    authorization_uri = URI.parse(authorization_url)
    started = get(build_conn(), authorization_uri.path <> "?" <> authorization_uri.query)
    assert redirected_to(started) == "/auth/user/oidc"
    assert get_resp_header(started, "cache-control") == ["no-store"]
    assert get_resp_header(started, "referrer-policy") == ["no-referrer"]

    request = Accounts.get_oidc_request!(id, authorize?: false)
    assert request.started_at

    user =
      Accounts.get_user!(
        json_response(get_json("/api/v1/session", token), 200)["data"]["account"]["id"],
        authorize?: false
      )

    code = OIDCRequest.random_secret()

    _completed_request =
      Accounts.complete_oidc_request!(
        request,
        request.revision,
        user.id,
        OIDCRequest.digest(code),
        authorize?: false
      )

    exchanged =
      post_json("/api/v1/oidc/cli/requests/#{id}/exchange", %{
        "request" => %{"code" => code, "verifier" => verifier}
      })

    assert %{"data" => %{"token" => session_token, "account" => %{"id" => user_id}}} =
             json_response(exchanged, 201)

    assert user_id == user.id

    assert %{"data" => %{"account" => %{"id" => ^user_id}}} =
             get_json("/api/v1/session", session_token) |> json_response(200)

    replay =
      post_json("/api/v1/oidc/cli/requests/#{id}/exchange", %{
        "request" => %{"code" => code, "verifier" => verifier}
      })

    assert %{"error" => %{"code" => "invalid_credentials"}} =
             json_response(replay, 401)
  end

  defp configure_oidc!(token, enabled \\ true) do
    put_json(
      "/api/v1/oidc/provider",
      %{
        "oidc_provider" => %{
          "issuer" => "https://identity.example.test/realms/opsonde",
          "client_id" => "opsonde",
          "client_secret" => "secret",
          "enabled" => enabled
        }
      },
      token
    )
    |> json_response(200)
  end

  defp bootstrap_and_sign_in! do
    post_json("/api/v1/accounts/bootstrap", %{
      "account" => %{
        "email" => "oidc-api-admin@example.com",
        "password" => @password,
        "password_confirmation" => @password
      }
    })
    |> json_response(201)

    post_json("/api/v1/sessions", %{
      "session" => %{"email" => "oidc-api-admin@example.com", "password" => @password}
    })
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token \\ nil), do: request(:get, path, nil, token)
  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)
  defp put_json(path, body, token), do: request(:put, path, body, token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
