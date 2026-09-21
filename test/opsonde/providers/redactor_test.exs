defmodule Opsonde.Providers.RedactorTest do
  use ExUnit.Case, async: true

  alias Opsonde.Providers.Redactor

  test "redacts secrets without destroying non-secret connection identifiers" do
    credentials = %{
      "username" => "opsonde",
      "auth_method" => "password",
      "password" => "correct horse battery staple"
    }

    output = "opsonde-validation.service belongs to opsonde; correct horse battery staple"

    assert Redactor.message(output, credentials) ==
             "opsonde-validation.service belongs to opsonde; [REDACTED]"
  end

  test "redacts nested values only when they belong to a secret field" do
    credentials = %{
      "endpoint" => %{"host" => "switch-01", "port" => 22},
      "client_secret" => %{"current" => "nested-secret"}
    }

    assert Redactor.message("switch-01:22 nested-secret", credentials) ==
             "switch-01:22 [REDACTED]"
  end
end
