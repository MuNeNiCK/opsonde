defmodule Opsonde.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Opsonde.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:opsonde, :token_signing_secret)
  end

  def oidc_callback_uri do
    base = Application.fetch_env!(:opsonde, :oidc_redirect_base_url)
    uri = URI.parse(base)
    suffix = Path.join(["user", "oidc", "callback"])

    path =
      if String.ends_with?(uri.path || "", suffix) do
        uri.path
      else
        Path.join([uri.path || "/", suffix])
      end

    to_string(%URI{uri | path: path})
  end

  def public_url(path) do
    public = Application.fetch_env!(:opsonde, :oidc_redirect_base_url) |> URI.parse()
    destination = URI.parse(path)

    to_string(%URI{
      destination
      | scheme: public.scheme,
        host: public.host,
        port: public.port,
        userinfo: nil
    })
  end
end
