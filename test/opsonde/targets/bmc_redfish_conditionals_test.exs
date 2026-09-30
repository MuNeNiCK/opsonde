defmodule Opsonde.Targets.BMCRedfishConditionalsTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.Redfish
  alias Opsonde.Targets.TargetRequest.Request

  @system_path "/redfish/v1/Systems/1"
  @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

  defmodule Stub do
    import Plug.Conn

    @system_path "/redfish/v1/Systems/1"
    @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

    def init(agent), do: agent

    def call(conn, agent) do
      Agent.update(
        agent,
        &Map.update(&1, :paths, [conn.request_path], fn paths -> [conn.request_path | paths] end)
      )

      if get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("tester:secret")] do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Systems"} = conn, agent) do
      if Agent.get(agent, &Map.get(&1, :no_system, false)),
        do: send_resp(conn, 404, ""),
        else: json(conn, 200, %{"Members" => [%{"@odata.id" => @system_path}]})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/"} = conn, _agent) do
      json(conn, 200, %{"@odata.id" => "/redfish/v1/", "RedfishVersion" => "1.16.0"})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Bundle/content"} = conn, _agent) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, <<255, 0, 1, 2, 255>>)
    end

    defp route(%{method: "PUT", request_path: "/redfish/v1/Oem/Bundle/content"} = conn, agent) do
      {:ok, bytes, conn} = read_body(conn)

      Agent.update(
        agent,
        &Map.put(&1, :file_input, {bytes, get_req_header(conn, "content-type")})
      )

      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, bytes)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Bundle/Interrupted"} = conn, _agent) do
      conn = send_chunked(conn, 200)
      {:ok, _conn} = chunk(conn, <<255, 0>>)
      Process.sleep(50)
      Process.exit(self(), :kill)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Bundle/Cancelled"} = conn, agent) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, <<255, 0>>)
      Agent.update(agent, &Map.put(&1, :cancelled, true))
      Process.sleep(150)
      conn
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/UpdateService/upload"} = conn, agent) do
      {:ok, parameter_headers, conn} = read_part_headers(conn)
      {:ok, parameters, conn} = read_part_body(conn, [])
      {:ok, file_headers, conn} = read_part_headers(conn)
      {:ok, bytes, conn} = read_part_body(conn, [])
      {:done, conn} = read_part_headers(conn)

      Agent.update(
        agent,
        &Map.put(&1, :multipart_input, {parameter_headers, parameters, file_headers, bytes})
      )

      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/2")
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(202, <<255, 0, 1, 2, 255>>)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Property"} = conn, agent) do
      if conn.method == "PATCH" do
        {:ok, body, _conn} = read_body(conn)
        %{"Name" => name} = Jason.decode!(body)
        Agent.update(agent, &%{&1 | name: name, writes: &1.writes + 1})
        send_resp(conn, 204, "")
      else
        json(conn, 200, %{"Name" => Agent.get(agent, & &1.name)})
      end
    end

    defp route(%{method: "GET", request_path: @system_path} = conn, agent) do
      state = Agent.get(agent, & &1)

      conn
      |> put_resp_header("etag", ~s("rev-#{state.revision}"))
      |> json(200, %{
        "@odata.id" => @system_path,
        "UUID" => @uuid,
        "PowerState" => state.power,
        "Name" => state.name,
        "Actions" => %{
          "#ComputerSystem.Reset" => %{
            "target" => @system_path <> "/Actions/ComputerSystem.Reset",
            "ResetType@Redfish.AllowableValues" => ["ForceOff", "On"]
          }
        }
      })
    end

    defp route(
           %{method: "POST", request_path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"} =
             conn,
           agent
         ) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body) do
        %{"ResetType" => "ForceOff"} ->
          Agent.update(agent, &%{&1 | power: "Off", writes: &1.writes + 1})
          json(conn, 200, %{})

        _ ->
          send_resp(conn, 400, "")
      end
    end

    defp route(%{method: "PATCH", request_path: @system_path} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      expected = Agent.get(agent, &~s("rev-#{&1.revision}"))

      if get_req_header(conn, "if-match") == [expected] do
        %{"Name" => name} = Jason.decode!(body)
        Agent.update(agent, &%{&1 | name: name, revision: &1.revision + 1, writes: &1.writes + 1})
        send_resp(conn, 204, "")
      else
        send_resp(conn, 412, Jason.encode!(%{"error" => "precondition failed"}))
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Pages"} = conn, _agent) do
      case conn.query_string do
        "page=2" ->
          json(conn, 200, %{"Members" => [%{"Id" => "second"}]})

        "" ->
          json(conn, 200, %{
            "Members" => [%{"Id" => "first"}],
            "Members@odata.nextLink" => "?page=2"
          })
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Loop"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [%{"Id" => "repeated"}],
        "Members@odata.nextLink" => "/redfish/v1/Oem/Loop"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Endless"} = conn, _agent) do
      page =
        case URI.decode_query(conn.query_string) do
          %{"page" => value} -> String.to_integer(value)
          _ -> 1
        end

      json(conn, 200, %{
        "Members" => [%{"Id" => Integer.to_string(page)}],
        "Members@odata.nextLink" => "?page=#{page + 1}"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Cross"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [],
        "Members@odata.nextLink" => "https://other.example/redfish/v1/Oem/Pages"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Large"} = conn, _agent) do
      json(conn, 200, %{"Value" => String.duplicate("x", 70_000)})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Visible"} = conn, _agent) do
      json(conn, 200, %{
        "Result" => "safe",
        "hidden" => "private-value",
        "Nested" => %{"Public" => "visible", "Private" => "private-value"}
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      json(conn, 200, %{"Result" => "safe", "Password" => "fixture-secret"})
    end

    defp route(%{method: "HEAD", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      conn
      |> put_resp_header("etag", ~s("oem-1"))
      |> send_resp(200, "")
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Wrong"} = conn, _agent) do
      json(conn, 200, %{"Result" => %{"unexpected" => "object"}})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Echo"} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      %{"Password" => secret} = Jason.decode!(body)
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      json(conn, 200, %{"Result" => Base.encode64(secret), "Message" => "changed"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Plain"} = conn, _agent) do
      json(conn, 200, %{"Result" => "done", "hidden" => "private-value"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Async"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/1?token=private-value")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/AsyncSafe"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/2")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Drop"} = _conn, agent) do
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      Process.exit(self(), :kill)
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Malformed"} = conn, _agent),
      do: send_resp(conn, 200, "[")

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Malformed"} = conn, agent) do
      Agent.update(agent, &%{&1 | name: "changed", writes: &1.writes + 1})
      send_resp(conn, 200, "[")
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Redirect"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/Oem/Pages")
      |> send_resp(302, "")
    end

    defp route(conn, _agent), do: send_resp(conn, 404, "")

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  test "checked Redfish Method returns exact binary file content without JSON decoding",
       context do
    request = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.redfish.observe",
      operation: "request.observe",
      parameters: %{
        "method" => "GET",
        "uri" => "/redfish/v1/Oem/Bundle/content",
        "accept" => "application/octet-stream",
        "response_file" => %{"name" => "bundle.bin", "media_type" => "application/octet-stream"}
      }
    }

    result =
      request
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    file = result.facts["file"]
    assert file["size_bytes"] == 5
    assert file["sha256"] == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert result.facts["response"] == %{}

    assert {:ok, _} =
             JSV.validate(
               result.facts,
               JSV.build!(
                 Enum.find(
                   context.method.operation_catalog.observations,
                   &(&1.capability == "request.redfish.observe")
                 ).output_schema
               )
             )
  end

  test "checked Redfish effects send immutable raw and native multipart files", context do
    bytes = <<255, 0, 1, 2, 255>>
    raw = stage_file(context, bytes, "raw.bin", "application/octet-stream")
    boundary = "opsonde-wire-boundary"
    media = "multipart/form-data; boundary=#{boundary}"

    multipart =
      IO.iodata_to_binary([
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"UpdateParameters\"\r\nContent-Type: application/json\r\n\r\n{}\r\n",
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"UpdateFile\"; filename=\"firmware.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        bytes,
        "\r\n--#{boundary}--\r\n"
      ])

    envelope = stage_file(context, multipart, "request.multipart", media)

    for {verb, uri, input, content_type, outcome} <- [
          {"PUT", "/redfish/v1/Oem/Bundle/content", raw, "application/octet-stream", :applied},
          {"POST", "/redfish/v1/UpdateService/upload", envelope, media, :unknown}
        ] do
      parameters = %{
        "method" => verb,
        "uri" => uri,
        "body_file" => "payload",
        "files" => %{"payload" => input},
        "content_type" => content_type,
        "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
      }

      clearance =
        file_request(context, :effect, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      result =
        Targets.dispatch_target_effect!(clearance, %{},
          actor: context.operator,
          authorize?: false
        )

      assert result.status == outcome

      assert Targets.read_bound_artifact_chunk!(result.details["file"], 0,
               actor: context.operator
             ) == bytes

      assert result.details["file"]["sha256"] ==
               "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

      if verb == "POST",
        do: assert(result.details["task_location"] == "/redfish/v1/TaskService/TaskMonitors/2")

      catalog =
        Enum.find(
          context.method.operation_catalog.effects,
          &(&1.capability == "request.redfish.effect")
        )

      assert {:ok, _} =
               JSV.validate(
                 %{"selectors" => %{}, "parameters" => parameters},
                 JSV.build!(catalog.input_schema)
               )

      for invalid <- [
            Map.put(parameters, "body", %{}),
            Map.put(parameters, "body_file", "missing"),
            Map.put(parameters, "uri", "https://other.example/redfish/v1/UpdateService/upload")
          ] do
        assert {:error, _} =
                 Targets.clear_target_request(file_request(context, :effect, invalid),
                   actor: context.operator
                 )
      end

      Targets.revoke_artifact!(input["id"], actor: context.operator)

      assert {:error, _} =
               Targets.dispatch_target_effect(clearance, %{},
                 actor: context.operator,
                 authorize?: false
               )
    end

    assert Agent.get(context.agent, & &1.file_input) == {bytes, ["application/octet-stream"]}

    {parameter_headers, parameters, file_headers, upload} =
      Agent.get(context.agent, & &1.multipart_input)

    assert parameters == "{}"
    assert upload == bytes

    assert List.keyfind(parameter_headers, "content-disposition", 0) ==
             {"content-disposition", "form-data; name=\"UpdateParameters\""}

    assert List.keyfind(file_headers, "content-disposition", 0) ==
             {"content-disposition", "form-data; name=\"UpdateFile\"; filename=\"firmware.bin\""}

    assert List.keyfind(file_headers, "content-type", 0) ==
             {"content-type", "application/octet-stream"}

    paths = Agent.get(context.agent, & &1.paths)
    assert Enum.count(paths, &(&1 == "/redfish/v1/UpdateService/upload")) == 1
    # One raw PUT, plus no calls after the input file was revoked.
    assert Enum.count(paths, &(&1 == "/redfish/v1/Oem/Bundle/content")) == 1
  end

  test "Redfish overflow and interruption never publish partial files", context do
    previous = Application.get_env(:opsonde, :artifact_limits)
    Application.put_env(:opsonde, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 4})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:opsonde, :artifact_limits, previous),
        else: Application.delete_env(:opsonde, :artifact_limits)
    end)

    for uri <- ["/redfish/v1/Oem/Bundle/content", "/redfish/v1/Oem/Bundle/Interrupted"] do
      clearance =
        file_request(context, :observation, %{
          "method" => "GET",
          "uri" => uri,
          "response_file" => %{
            "name" => "partial.bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, _} =
               Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)
    end

    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving
      assert receipt.received_bytes <= 4
      assert is_nil(receipt.sha256)

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
    end
  end

  test "cancelled Redfish file effects remain unknown without replay", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Bundle/Cancelled",
        "body" => %{},
        "response_file" => %{
          "name" => "cancelled.bin",
          "media_type" => "application/octet-stream"
        }
      })
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert Targets.page_artifacts!(context.target.id, actor: context.operator).results == []

    result =
      Targets.dispatch_target_effect!(
        clearance,
        %{cancelled?: fn -> Agent.get(context.agent, &Map.get(&1, :cancelled, false)) end},
        actor: context.operator,
        authorize?: false
      )

    assert result.status == :unknown
    refute Map.has_key?(result.details, "file")
    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(
             context.agent,
             &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/Bundle/Cancelled" end)
           ) == 1
  end

  test "lost Redfish file effect response retains receipt identity without replay", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Drop",
        "body" => %{},
        "response_file" => %{"name" => "lost.bin", "media_type" => "application/octet-stream"}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.echo_calls) == 1
    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert result.details["reason"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "failed Redfish file publication cannot report success or resend the body", context do
    input = stage_file(context, <<255, 0, 1, 2, 255>>, "request.bin", "application/octet-stream")

    Opsonde.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_redfish_file_ready() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' THEN RAISE EXCEPTION 'injected file publication failure'; END IF;
      RETURN NEW;
    END $$;
    """)

    Opsonde.Repo.query!(
      "CREATE TRIGGER reject_redfish_file_ready BEFORE UPDATE ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_redfish_file_ready()"
    )

    clearance =
      file_request(context, :effect, %{
        "method" => "PUT",
        "uri" => "/redfish/v1/Oem/Bundle/content",
        "body_file" => "payload",
        "files" => %{"payload" => input},
        "content_type" => "application/octet-stream",
        "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    receipt = Enum.find(receipts, &(&1.id != input["id"]))
    assert receipt.status == :receiving
    assert receipt.received_bytes == 5
    assert result.details["reason"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(
             context.agent,
             &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/Bundle/content" end)
           ) == 1
  end

  test "an undecodable reply after a Redfish change stays unknown", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Malformed",
        "body" => %{}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"changed", 1}
  end

  test "generic Method registers and dispatches without a selected ComputerSystem", context do
    Agent.update(context.agent, &Map.merge(&1, %{no_system: true, paths: []}))

    provider =
      Providers.create_provider!(
        "service-root-only",
        :target,
        "redfish",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "tester", "password" => "secret"},
        actor: context.admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(
        provider,
        context.method.endpoint,
        context.admin
      )

    assert {:ok, _catalog} = checked

    capabilities =
      Providers.target_capabilities!(
        provider.id,
        %Target.CapabilitiesRequest{
          provider_revision: provider.revision,
          connection: %Target.Connection{endpoint: context.method.endpoint}
        },
        %{},
        actor: context.admin
      )

    assert Target.capability_names(capabilities) == [
             "request.redfish.observe",
             "request.redfish.effect"
           ]

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "Service root",
        "redfish",
        context.method.endpoint,
        provider.revision,
        100,
        Target.capability_names(capabilities),
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    read = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: "request.redfish.observe",
      operation: "request.observe",
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    clearance = Targets.clear_target_request!(read, actor: context.operator)
    observation = Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
    assert observation.facts["response"]["Result"] == "safe"

    write = %{
      read
      | kind: :effect,
        authority_mode: :full_access,
        capability: "request.redfish.effect",
        operation: "request.execute",
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        parameters: %{
          "method" => "PATCH",
          "uri" => "/redfish/v1/Oem/Property",
          "body" => %{"Name" => "generic"}
        }
    }

    clearance = Targets.clear_target_request!(write, actor: context.operator)

    assert %{status: :applied, details: %{"http_status" => 204}} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.name) == "generic"
    read = %{read | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Property"}}
    clearance = Targets.clear_target_request!(read, actor: context.operator)

    assert %Target.Observation{facts: %{"response" => %{"Name" => "generic"}}} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    refute Enum.any?(
             Agent.get(context.agent, & &1.paths),
             &String.starts_with?(&1, "/redfish/v1/Systems")
           )
  end

  test "Redfish Method effects validate URI and ETag and preserve uncertain results", context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.effects, fn operation ->
             operation.capability == "request.redfish.effect"
           end)

    assert "request.redfish.effect" in Redfish.access_method_profile().capabilities

    request = method_effect_request(context, "PATCH", @system_path, %{"Name" => "requested"})
    request = %{request | selectors: %{"if_match" => ~s("rev-1")}}

    assert {:ok, %{status: :applied, details: %{"http_status" => 204}}} =
             Redfish.effect(state, request, %{})

    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"requested", 1}

    for uri <- ["https://other.example/redfish/v1/Systems/1", "/redfish/v1/../Oem/Plain"] do
      assert {:error, :failed, _} =
               Redfish.effect(state, method_effect_request(context, "POST", uri, %{}), %{})
    end

    oversized =
      method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{
        "Value" => String.duplicate("x", 70_000)
      })

    assert {:error, :failed, _} = Redfish.effect(state, oversized, %{})

    assert {:ok, %{status: :applied, details: plain}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{}),
               %{}
             )

    assert plain == %{"http_status" => 200, "response_redacted" => true}

    assert {:ok, %{status: :unknown, details: async}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/AsyncSafe", %{}),
               %{}
             )

    assert async["task_location"] == "/redfish/v1/TaskService/TaskMonitors/2"

    assert {:ok, %{status: :unknown, details: lost}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Drop", %{}),
               %{}
             )

    assert lost["reason"] =~ "lost"
    assert Agent.get(context.agent, & &1.echo_calls) == 1
  end

  test "named controller profiles share generic requests and uncertain delivery", context do
    for type <- ["hpe-ilo-redfish", "dell-idrac-redfish"] do
      provider =
        Providers.create_provider!(
          type,
          :target,
          type,
          %{
            "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
          },
          %{"username" => "tester", "password" => "secret"},
          actor: context.admin
        )

      checked =
        Opsonde.TargetConnectionFixture.check_connection(
          provider,
          context.method.endpoint,
          context.admin
        )

      assert {:ok, _catalog} = checked

      capabilities =
        Providers.target_capabilities!(
          provider.id,
          %Target.CapabilitiesRequest{
            provider_revision: provider.revision,
            connection: %Target.Connection{endpoint: context.method.endpoint}
          },
          %{},
          actor: context.admin
        )

      assert Target.capability_names(capabilities) == [
               "request.redfish.observe",
               "request.redfish.effect"
             ]

      {:ok, adapter} = Providers.Registry.fetch(type, Target)
      assert adapter.type() == type
      assert adapter.access_method_profile().method == "redfish"

      read = %Target.ObservationRequest{
        provider_revision: provider.revision,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        connection: %Target.Connection{endpoint: context.method.endpoint},
        capability: "request.redfish.observe",
        operation: "request.observe",
        authorization_digest: "fixture",
        parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
      }

      assert %Target.Observation{facts: %{"response" => %{"Result" => "safe"}}} =
               Providers.target_observe!(provider.id, read, %{},
                 actor: context.admin,
                 authorize?: false
               )

      effect =
        struct!(
          Target.EffectRequest,
          Map.merge(
            Map.take(
              Map.from_struct(read),
              [
                :provider_revision,
                :target_id,
                :target_revision,
                :access_method_id,
                :access_method_revision,
                :connection,
                :authorization_digest
              ]
            ),
            %{
              capability: "request.redfish.effect",
              operation: "request.execute",
              operation_id: Ecto.UUID.generate(),
              idempotency_key: Ecto.UUID.generate(),
              parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Drop", "body" => %{}}
            }
          )
        )

      assert %Target.EffectResult{status: :unknown, details: %{"reason" => reason}} =
               Providers.target_effect!(provider.id, effect, %{},
                 actor: context.admin,
                 authorize?: false
               )

      assert reason =~ "lost"
    end

    assert Agent.get(context.agent, & &1.echo_calls) == 2
  end

  test "power observation and effect keep the observed-state precondition", context do
    {:ok, state} = redfish_state(context.method.endpoint)

    observation = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "observe.power",
      operation: "bmc.power.inspect",
      authorization_digest: "fixture"
    }

    assert {:ok, %Target.Observation{facts: %{"power_state" => "on"}}} =
             Redfish.observe(state, observation, %{})

    effect = %Target.EffectRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: observation.connection,
      capability: "effect.power",
      operation: "bmc.power.off",
      authorization_digest: "fixture",
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: %{"observed_power_state" => "off"}
    }

    assert {:error, :failed, _} = Redfish.effect(state, effect, %{})
    assert Agent.get(context.agent, & &1.writes) == 0

    assert {:ok, %Target.EffectResult{status: :applied}} =
             Redfish.effect(
               state,
               %{effect | parameters: %{"observed_power_state" => "on"}},
               %{}
             )

    assert Agent.get(context.agent, & &1.writes) == 1

    assert {:ok, %Target.Observation{facts: %{"power_state" => "off"}}} =
             Redfish.observe(state, observation, %{})
  end

  test "System identity constrains power convenience without blocking the protocol", context do
    {:ok, state} = redfish_state(context.method.endpoint)
    state = %{state | expected_uuid: "different-system"}
    assert :ok = Redfish.check(state, %{"endpoint" => context.method.endpoint})
    assert {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Target.capability_names(capabilities) == [
             "request.redfish.observe",
             "request.redfish.effect"
           ]

    request = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    assert {:ok, %Target.Observation{facts: %{"response" => %{"Result" => "safe"}}}} =
             Redfish.observe(state, request, %{})

    power = %{
      request
      | capability: "observe.power",
        operation: "bmc.power.inspect",
        parameters: %{}
    }

    assert {:error, :failed, message} = Redfish.observe(state, power, %{})
    assert message =~ "identity"
    assert Agent.get(context.agent, & &1.writes) == 0
  end

  defp stage_file(context, bytes, name, media) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    file =
      Targets.begin_artifact!(
        context.target.id,
        name,
        media,
        byte_size(bytes),
        hash,
        "redfish-file-#{System.unique_integer()}",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, bytes, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  defp file_request(context, kind, parameters) do
    %Request{
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability:
        if(kind == :effect, do: "request.redfish.effect", else: "request.redfish.observe"),
      operation: if(kind == :effect, do: "request.execute", else: "request.observe"),
      operation_id: "redfish-file-#{System.unique_integer()}",
      idempotency_key: "redfish-file-#{System.unique_integer()}",
      parameters: parameters
    }
  end

  defp method_effect_request(context, method, uri, body) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: %{"method" => method, "uri" => uri, "body" => body}
    }
  end

  test "Redfish Method reads standard and OEM resources without operation registration",
       context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.observations, fn operation ->
             operation.capability == "request.redfish.observe"
           end)

    assert "request.redfish.observe" in Redfish.access_method_profile().capabilities

    assert %Target.Capabilities{} =
             Providers.target_capabilities!(
               context.method.provider_id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.method.provider_revision,
                 connection: %Target.Connection{endpoint: context.method.endpoint}
               },
               %{},
               actor: context.admin
             )

    request = %Target.ObservationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture"
    }

    for {uri, expected} <- [
          {@system_path, "original"},
          {"/redfish/v1/Oem/Example", "safe"}
        ] do
      assert {:ok, observation} =
               Redfish.observe(
                 state,
                 %{request | parameters: %{"method" => "GET", "uri" => uri}},
                 %{}
               )

      assert observation.facts["response"]["Name"] == expected or
               observation.facts["response"]["Result"] == expected

      refute inspect(observation) =~ "fixture-secret"
    end

    assert {:ok, head} =
             Redfish.observe(
               state,
               %{
                 request
                 | parameters: %{"method" => "HEAD", "uri" => "/redfish/v1/Oem/Example"}
               },
               %{}
             )

    assert head.facts == %{"http_status" => 200, "response" => %{}}
    assert [%{"etag" => ~s("oem-1")}] = Enum.map(head.evidence, &Map.take(&1, ["etag"]))

    for parameters <- [
          %{"method" => "POST", "uri" => "/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "https://other.example/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example", "extra" => true}
        ] do
      assert {:error, :failed, _} =
               Redfish.observe(state, %{request | parameters: parameters}, %{})
    end

    assert {:error, :failed, _} =
             Redfish.observe(
               state,
               %{request | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Large"}},
               %{}
             )
  end

  test "Provider classifies exact Redfish verbs and rejects malformed connection or URI",
       context do
    request = %Target.MethodRequest{
      provider_revision: context.method.provider_revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      selectors: %{},
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    classify = fn input ->
      Providers.target_classify(context.method.provider_id, input, %{}, authorize?: false)
    end

    assert {:ok, %Target.RequestClassification{kind: :observation}} = classify.(request)

    write = %{
      request
      | capability: "request.redfish.effect",
        operation: "request.execute",
        parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Plain", "body" => %{}}
    }

    assert {:ok, %Target.RequestClassification{kind: :effect}} = classify.(write)

    for invalid <- [
          %{request | parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Plain"}},
          %{request | connection: %Target.Connection{endpoint: "https://other.example/redfish"}},
          %{
            write
            | parameters: %{
                "method" => "POST",
                "uri" => "/redfish/v1/../Oem/Plain",
                "body" => %{}
              }
          }
        ] do
      assert {:error, _} = classify.(invalid)
    end

    assert Agent.get(context.agent, & &1.writes) == 0
  end

  test "Case projection reads each checked Method catalog without contacting either endpoint",
       context do
    second_agent =
      start_supervised!(%{
        id: :second_redfish_state,
        start:
          {Agent, :start_link,
           [
             fn ->
               %{revision: 1, name: "second", power: "Unavailable", writes: 0, echo_calls: 0}
             end
           ]}
      })

    second_server =
      start_supervised!(%{
        id: :second_redfish_server,
        start:
          {Bandit, :start_link,
           [
             [
               plug: {Stub, second_agent},
               scheme: :https,
               port: 0,
               certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
               keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
               startup_log: false
             ]
           ]}
      })

    {:ok, {_address, port}} = ThousandIsland.listener_info(second_server)
    endpoint = "https://127.0.0.1:#{port}"

    second =
      Targets.create_access_method!(
        context.target.id,
        context.method.provider_id,
        "Second controller",
        "redfish",
        endpoint,
        context.method.provider_revision,
        200,
        ["request.redfish.observe", "request.redfish.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    Agent.update(context.agent, &Map.put(&1, :paths, []))
    Agent.update(second_agent, &Map.put(&1, :paths, []))

    incident =
      Opsonde.Cases.open_case!(
        :manual,
        "test",
        "checked-method-projection",
        "Investigate controller reachability",
        :warning,
        %{"observed_problem" => "controller alert", "desired_outcome" => "controller healthy"},
        context.target.id,
        :en,
        actor: context.admin
      )

    run = Opsonde.Cases.active_resolution_run!(incident.id, authorize?: false)

    turn =
      Opsonde.Cases.start_turn!(
        incident.id,
        run.id,
        "checked-method-projection",
        %{"objective" => "Investigate the controller"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    selection = %Opsonde.Providers.AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    assert {:ok, projection} =
             Opsonde.Cases.Turn.ResolverProjection.build(turn.value.id, selection)

    assert Enum.any?(
             projection.observation_tools,
             &(&1.access_method_id == context.method.id and &1.capability == "observe.power")
           )

    assert Enum.map(
             Enum.filter(projection.observation_tools, &(&1.access_method_id == second.id)),
             & &1.capability
           ) == ["request.redfish.observe"]

    assert Enum.map(
             Enum.filter(
               projection.proposal_tools,
               &(&1.access_method_id == second.id and &1.request_kind == :effect)
             ),
             & &1.capability
           ) == ["request.redfish.effect"]

    assert Agent.get(context.agent, & &1.writes) == 0
    assert Agent.get(second_agent, & &1.writes) == 0
    assert Agent.get(context.agent, & &1.paths) == []
    assert Agent.get(second_agent, & &1.paths) == []
  end

  defp redfish_state(endpoint) do
    with {:ok, state} <-
           Redfish.build(
             %{
               "system_path" => @system_path,
               "expected_uuid" => @uuid,
               "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
             },
             %{"username" => "tester", "password" => "secret"}
           ),
         do: Redfish.bind_connection(state, %Target.Connection{endpoint: endpoint})
  end

  setup do
    agent =
      start_supervised!(
        {Agent, fn -> %{revision: 1, name: "original", power: "On", writes: 0, echo_calls: 0} end}
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "bmc-etag-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!("bmc-etag-operator@example.invalid", "test-only-password", :operator,
        actor: admin
      )

    target =
      Targets.create_target!("etag-host", "management_plane", "custom-bmc", %{}, nil,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "etag-bmc",
        :target,
        "redfish",
        %{
          "system_path" => @system_path,
          "expected_uuid" => @uuid,
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Redfish",
        "redfish",
        endpoint,
        provider.revision,
        100,
        ["observe.power", "request.redfish.observe", "request.redfish.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{admin: admin, operator: operator, target: target, method: method, agent: agent}
  end

  test "Method pagination stays on origin and rejects cycles", context do
    {:ok, state} = redfish_state(context.method.endpoint)

    request = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture"
    }

    assert {:ok, observation} =
             Redfish.observe(
               state,
               %{request | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Pages"}},
               %{}
             )

    assert length(observation.facts["response"]["Members"]) == 2

    for uri <- ["/redfish/v1/Oem/Loop", "/redfish/v1/Oem/Endless", "/redfish/v1/Oem/Cross"] do
      assert {:error, :failed, _} =
               Redfish.observe(
                 state,
                 %{request | parameters: %{"method" => "GET", "uri" => uri}},
                 %{}
               )
    end
  end
end
