defmodule OpsondeWeb.API.V1.OIDCControllerTest do
  use OpsondeWeb.ConnCase, async: false

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

  defp configure_oidc!(token, enabled) do
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
