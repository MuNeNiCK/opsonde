defmodule Opsonde.Targets.SFTPTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Targets.TargetRequest.Request
  @password "correct horse battery staple"
  @bytes <<0, 255, 1, 128, 10>>

  defmodule Backend do
    @behaviour :ssh_sftpd_file_api
    for {name, arity} <- [
          delete: 2,
          del_dir: 2,
          get_cwd: 1,
          is_dir: 2,
          list_dir: 2,
          make_dir: 2,
          make_symlink: 3,
          position: 3,
          read_file_info: 2,
          read_link: 2,
          read_link_info: 2,
          rename: 3,
          write_file_info: 3
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)),
        do: apply(:ssh_sftpd_file, unquote(name), [unquote_splicing(args)])
    end

    @impl true
    def open(path, flags, state) do
      result = :ssh_sftpd_file.open(path, flags, state)
      Agent.update(state, fn value -> %{value | opens: value.opens + 1} end)
      result
    end

    @impl true
    def close(handle, state), do: :ssh_sftpd_file.close(handle, state)

    @impl true
    def read(handle, count, state) do
      result = :ssh_sftpd_file.read(handle, count, state)

      control =
        Agent.get_and_update(state, fn value -> {value, %{value | reads: value.reads + 1}} end)

      Process.sleep(control.read_delay)
      if control.read_drop, do: exit(:kill)
      result
    end

    @impl true
    def write(handle, data, state) do
      result = :ssh_sftpd_file.write(handle, data, state)

      control =
        Agent.get_and_update(state, fn value -> {value, %{value | writes: value.writes + 1}} end)

      Process.sleep(control.write_delay)
      if control.write_drop, do: exit(:kill)
      result
    end
  end

  setup_all do
    directory = Path.join(System.tmp_dir!(), "opsonde-sftp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2048, 65537})
    private = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    File.write!(Path.join(directory, "ssh_host_rsa_key"), :public_key.pem_encode([private]))
    File.chmod!(Path.join(directory, "ssh_host_rsa_key"), 0o600)
    File.write!(Path.join(directory, "download.bin"), @bytes)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          opens: 0,
          reads: 0,
          writes: 0,
          read_delay: 0,
          write_delay: 0,
          read_drop: false,
          write_drop: false
        }
      end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        subsystems: [
          :ssh_sftpd.subsystem_spec(
            root: String.to_charlist(directory),
            file_handler: {Backend, agent}
          )
        ]
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    endpoint = "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"

    fingerprint =
      host_key
      |> :ssh_file.extract_public_key()
      |> then(&:ssh.hostkey_fingerprint(:sha256, &1))
      |> to_string()

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(directory)
    end)

    %{directory: directory, endpoint: endpoint, fingerprint: fingerprint, agent: agent}
  end

  setup context do
    Agent.update(context.agent, fn _ ->
      %{
        opens: 0,
        reads: 0,
        writes: 0,
        read_delay: 0,
        write_delay: 0,
        read_drop: false,
        write_drop: false
      }
    end)

    admin = Accounts.bootstrap!("sftp-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("sftp-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("sftp-viewer@example.com", @password, :viewer, actor: admin)
    adapter = Map.get(context, :adapter, "ssh")

    provider =
      Providers.create_provider!(
        "SFTP " <> adapter,
        :target,
        adapter,
        %{
          "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
          "connect_timeout_ms" => 2000,
          "operation_timeout_ms" => 1000
        },
        %{"username" => "tester", "auth_method" => "password", "password" => "secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(
        "SFTP peer",
        Map.get(context, :kind, "network_device"),
        Map.get(context, :type, "custom-network-device"),
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "same SSH Method",
        Map.get(context, :protocol, "ssh"),
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.observe", "request.ssh.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    assert method.check_status == :passed

    Map.merge(context, %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      provider: provider,
      target: target,
      method: method
    })
  end

  test "native SFTP cancellation and lost replies preserve uncertainty without replay", context do
    file = stage_file(context)

    params = %{
      "path" => "/interrupted.bin",
      "body_file" => "payload",
      "files" => %{"payload" => file}
    }

    clearance =
      request(context, :effect, "sftp.write_file", params)
      |> Targets.clear_target_request!(actor: context.operator)

    before = Agent.get(context.agent, & &1.opens)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.opens) == before

    Agent.update(context.agent, &%{&1 | write_delay: 300})
    cancel = fn -> Agent.get(context.agent, &(&1.writes > 0)) end

    result =
      Targets.dispatch_target_effect!(clearance, %{cancelled?: cancel},
        actor: context.operator,
        authorize?: false
      )

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 1
    assert File.read!(Path.join(context.directory, "interrupted.bin")) == @bytes

    Agent.update(context.agent, &%{&1 | write_delay: 0, write_drop: true})

    dropped =
      request(context, :effect, "sftp.write_file", params)
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert dropped.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 2
  end

  test "cancelled or dropped SFTP downloads cannot publish complete files", context do
    parameters = %{
      "path" => "/download.bin",
      "response_file" => %{"name" => "partial.bin", "media_type" => "application/octet-stream"}
    }

    Agent.update(context.agent, &%{&1 | read_delay: 300})
    cancel = fn -> Agent.get(context.agent, &(&1.reads > 0)) end

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", parameters)
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{cancelled?: cancel},
               actor: context.operator
             )

    Agent.update(context.agent, &%{&1 | read_delay: 0, read_drop: true})

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", parameters)
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving
      assert receipt.completion_reason == nil

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
    end

    assert Agent.get(context.agent, & &1.reads) == 2
  end

  test "revoked files, insufficient authority and stale Methods cannot open a remote file",
       context do
    file = stage_file(context)

    intent =
      request(context, :effect, "sftp.write_file", %{
        "path" => "/never-opened.bin",
        "body_file" => "payload",
        "files" => %{"payload" => file}
      })

    clearance = Targets.clear_target_request!(intent, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{}, actor: context.viewer)

    readonly =
      %{intent | authority_mode: :readonly}
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(readonly, %{},
               actor: context.operator,
               authorize?: false
             )

    Targets.revoke_artifact!(file["id"], actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    fresh = stage_file(context)
    fresh_intent = put_in(intent.parameters["files"]["payload"], fresh)
    stale = Targets.clear_target_request!(fresh_intent, actor: context.operator)

    Targets.update_access_method!(context.method, context.method.revision, %{priority: 90},
      actor: context.admin
    )

    assert {:error, _} =
             Targets.dispatch_target_effect(stale, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.opens) == 0
    refute File.exists?(Path.join(context.directory, "never-opened.bin"))
  end

  test "native transfer deadlines leave writes uncertain and reads unpublished", context do
    file = stage_file(context)
    Agent.update(context.agent, &%{&1 | write_delay: 1_500})

    result =
      request(context, :effect, "sftp.write_file", %{
        "path" => "/timed-out.bin",
        "body_file" => "payload",
        "files" => %{"payload" => file}
      })
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 1

    Agent.update(context.agent, &%{&1 | write_delay: 0, read_delay: 1_500})

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", %{
               "path" => "/download.bin",
               "response_file" => %{
                 "name" => "timeout.bin",
                 "media_type" => "application/octet-stream"
               }
             })
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    receipt =
      Targets.page_artifacts!(context.target.id, actor: context.operator).results
      |> Enum.find(&(&1.name == "timeout.bin"))

    assert receipt.status == :receiving
    assert receipt.completion_reason == nil
    assert Agent.get(context.agent, & &1.reads) == 1
  end

  test "empty and multi-chunk native files retain exact bytes in both directions", context do
    for bytes <- [<<>>, :binary.copy(@bytes, 60_001)] do
      suffix = Integer.to_string(byte_size(bytes))
      file = stage_file(context, bytes)
      remote = "/sized-" <> suffix <> ".bin"

      result =
        request(context, :effect, "sftp.write_file", %{
          "path" => remote,
          "body_file" => "payload",
          "files" => %{"payload" => file}
        })
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

      assert result.status == :applied
      assert result.details["bytes_written"] == byte_size(bytes)
      assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) == bytes

      downloaded =
        request(context, :observation, "sftp.read_file", %{
          "path" => remote,
          "response_file" => %{
            "name" => "sized-" <> suffix <> ".bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

      received = downloaded.facts["file"]
      assert received["size_bytes"] == byte_size(bytes)
      assert received["sha256"] == file["sha256"]

      actual =
        Opsonde.Providers.Target.FileWriter.stream(received, fn offset ->
          Targets.read_bound_artifact_chunk(received, offset, actor: context.operator)
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert actual == bytes
    end

    assert Agent.get(context.agent, & &1.writes) > 1
    assert Agent.get(context.agent, & &1.reads) > 2
  end

  defp stage_file(context, bytes \\ @bytes) do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "input.bin",
        "application/octet-stream",
        byte_size(bytes),
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        Ecto.UUID.generate(),
        actor: context.operator
      )

    bytes
    |> :binary.bin_to_list()
    |> Enum.chunk_every(262_144)
    |> Enum.reduce(0, fn chunk, offset ->
      binary = :binary.list_to_bin(chunk)
      Targets.append_artifact_chunk!(file.id, offset, binary, actor: context.operator)
      offset + byte_size(binary)
    end)

    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  test "SFTP receipt publication failure leaves downloaded bytes unpublished", context do
    Opsonde.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_sftp_completion() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' AND NEW.request_id = 'sftp-save-failure' THEN
        RAISE EXCEPTION 'test SFTP receipt publication unavailable';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    Opsonde.Repo.query!("""
    CREATE TRIGGER reject_sftp_completion BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_sftp_completion()
    """)

    read =
      request(context, :observation, "sftp.read_file", %{
        "path" => "/download.bin",
        "response_file" => %{"name" => "unsaved.bin", "media_type" => "application/octet-stream"}
      })

    read = %{read | operation_id: "sftp-save-failure"}

    assert {:error, _} =
             read
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.received_bytes == 5
    assert receipt.completion_reason == nil

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(context.agent, & &1.opens) == 1
    Opsonde.Repo.query!("DROP TRIGGER reject_sftp_completion ON artifacts")
  end

  for {adapter, kind, type, protocol} <- [
        {"ssh", "network_device", "custom-network-device", "ssh"},
        {"linux-ssh", "host", "linux", "ssh"},
        {"ios-xe-ssh", "network_device", "cisco_ios_xe", "ssh_cli"}
      ] do
    @tag adapter: adapter, kind: kind, type: type, protocol: protocol
    test "#{adapter} downloads and uploads exact binary files through one checked Method",
         context do
      assert Enum.any?(
               context.method.operation_catalog.observations,
               &(&1.operation == "sftp.read_file")
             )

      assert Enum.any?(
               context.method.operation_catalog.effects,
               &(&1.operation == "sftp.write_file")
             )

      read =
        request(context, :observation, "sftp.read_file", %{
          "path" => "/download.bin",
          "response_file" => %{
            "name" => "download.bin",
            "media_type" => "application/octet-stream"
          }
        })

      result =
        read
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

      assert result.facts["completion_reason"] == "eof"
      file = result.facts["file"]
      assert file["size_bytes"] == byte_size(@bytes)
      assert file["sha256"] == Base.encode16(:crypto.hash(:sha256, @bytes), case: :lower)
      assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) == @bytes

      assert Targets.get_artifact!(file["id"], actor: context.operator).request_id ==
               read.operation_id

      assert {:error, _} = Targets.read_bound_artifact_chunk(file, 0, actor: context.viewer)
      remote = "/uploaded-" <> context.adapter <> ".bin"
      parameters = %{"path" => remote, "body_file" => "payload", "files" => %{"payload" => file}}

      assert {:error, _} =
               request(context, :observation, "sftp.write_file", parameters)
               |> Targets.clear_target_request(actor: context.operator)

      effect =
        request(context, :effect, "sftp.write_file", parameters)
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

      assert effect.status == :applied
      assert effect.details["bytes_written"] == byte_size(@bytes)
      assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) == @bytes

      verification =
        request(context, :verification, "sftp.read_file", %{
          "path" => remote,
          "response_file" => %{"name" => "verify.bin", "media_type" => "application/octet-stream"}
        })

      verification = %{verification | expected: %{"sha256" => file["sha256"], "size_bytes" => 5}}

      verified =
        verification
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_verification!(%{}, actor: context.operator)

      assert verified.status == :verified
      assert verified.facts["file"]["sha256"] == file["sha256"]
    end
  end

  defp request(context, kind, operation, parameters) do
    id = Ecto.UUID.generate()

    %Request{
      kind: kind,
      authority_mode: if(kind == :effect, do: :full_access, else: :readonly),
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: if(kind == :effect, do: "request.ssh.effect", else: "request.ssh.observe"),
      operation: operation,
      operation_id: id,
      idempotency_key: if(kind == :effect, do: id),
      parameters: parameters
    }
  end
end
