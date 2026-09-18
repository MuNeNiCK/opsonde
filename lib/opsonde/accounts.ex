defmodule Opsonde.Accounts do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Accounts.User do
      define :bootstrap, action: :bootstrap, args: [:email, :password, :password_confirmation]
      define :create_user, action: :create_user, args: [:email, :password, :role]
      define :change_role, action: :change_role, args: [:role]
      define :list_users, action: :page
      define :get_user, action: :read, get_by: [:id]
      define :sign_in, action: :sign_in_with_password, args: [:email, :password]
      define :issue_session, action: :issue_session, args: [:user_id]
    end

    resource Opsonde.Accounts.Token
    resource Opsonde.Accounts.UserIdentity

    resource Opsonde.Accounts.OIDCProvider do
      define :configure_oidc, action: :configure
      define :current_oidc_provider, action: :current
    end

    resource Opsonde.Accounts.OIDCRequest do
      define :get_oidc_request, action: :get_by_id, args: [:id]

      define :create_oidc_link,
        action: :create_link,
        args: [:user_id, :start_token_digest, :expires_at]

      define :create_oidc_cli_login,
        action: :create_cli_login,
        args: [:start_token_digest, :verifier_digest, :redirect_uri, :expires_at]

      define :start_oidc_request, action: :start, args: [:expected_revision, :start_token]

      define :complete_oidc_request,
        action: :complete,
        args: [:expected_revision, :user_id, :code_digest]

      define :consume_oidc_request,
        action: :consume,
        args: [:expected_revision, :code, :verifier]
    end
  end
end
