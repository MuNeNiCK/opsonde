defmodule Opsonde.TargetConnectionFixture do
  @moduledoc false

  def input(adapter_type, endpoint) do
    protocol =
      Enum.find(
        Opsonde.Targets.TypeCatalog.snapshot().methods,
        &(&1.adapter_type == adapter_type)
      ).protocol

    certificate = File.read!("test/support/certs/kubernetes_fixture_ca.pem")

    case protocol do
      protocol when protocol in ["ssh", "netconf"] ->
        {%{
           "host_key_fingerprints" => %{
             endpoint => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
           }
         },
         %{"username" => "fixture", "auth_method" => "password", "password" => "fixture-password"}}

      "redfish" ->
        {%{"ca_certificate" => certificate},
         %{"username" => "fixture", "password" => "fixture-password"}}

      "ipmi" ->
        {%{}, %{"username" => "fixture", "password" => "fixture-password"}}

      "restconf" ->
        {%{"ca_certificate" => certificate},
         %{"username" => "fixture", "password" => "fixture-password"}}

      "http" ->
        {%{}, %{}}

      "kubernetes" ->
        kubeconfig = %{
          "apiVersion" => "v1",
          "kind" => "Config",
          "current-context" => "fixture",
          "clusters" => [
            %{
              "name" => "fixture",
              "cluster" => %{
                "server" => endpoint,
                "certificate-authority-data" => Base.encode64(certificate)
              }
            }
          ],
          "users" => [%{"name" => "fixture", "user" => %{"token" => "fixture-token"}}],
          "contexts" => [
            %{"name" => "fixture", "context" => %{"cluster" => "fixture", "user" => "fixture"}}
          ]
        }

        {%{}, %{"kubeconfig" => Jason.encode!(kubeconfig)}}
    end
  end
end
