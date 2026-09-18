defmodule Opsonde.Transports.HTTPS do
  @moduledoc false

  @max_ca_bytes 65_536

  def transport_options(ca_certificate, host)
      when (is_nil(ca_certificate) or is_binary(ca_certificate)) and is_binary(host) do
    with {:ok, additional} <- certificates(ca_certificate) do
      {:ok,
       [
         verify: :verify_peer,
         cacerts: :public_key.cacerts_get() ++ additional,
         server_name_indication: String.to_charlist(host),
         customize_hostname_check: [
           match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
         ]
       ]}
    end
  rescue
    _error -> {:error, :invalid_ca_certificate}
  end

  def transport_options(_ca_certificate, _host), do: {:error, :invalid_ca_certificate}

  defp certificates(nil), do: {:ok, []}

  defp certificates(pem) when byte_size(pem) <= @max_ca_bytes do
    certificates =
      pem
      |> :public_key.pem_decode()
      |> Enum.flat_map(fn
        {:Certificate, der, :not_encrypted} -> [der]
        _entry -> []
      end)

    if certificates == [],
      do: {:error, :invalid_ca_certificate},
      else: {:ok, certificates}
  rescue
    _error -> {:error, :invalid_ca_certificate}
  end

  defp certificates(_pem), do: {:error, :invalid_ca_certificate}
end
