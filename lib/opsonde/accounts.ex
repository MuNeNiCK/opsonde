defmodule Opsonde.Accounts do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Accounts.User do
      define :bootstrap, action: :bootstrap, args: [:email, :password, :password_confirmation]
      define :create_user, action: :create_user, args: [:email, :password, :role]
      define :change_role, action: :change_role, args: [:role]
      define :get_user, action: :read, get_by: [:id]
      define :sign_in, action: :sign_in_with_password, args: [:email, :password]
    end

    resource Opsonde.Accounts.Token
  end
end
