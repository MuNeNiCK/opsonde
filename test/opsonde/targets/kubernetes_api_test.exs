defmodule Opsonde.Targets.KubernetesAPITest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Kubernetes.API
  alias Opsonde.Targets.PolicyRequest

  @password "correct horse battery staple"
  @namespace "bounded-namespace"
  @capabilities [
    "observe.workloads",
    "observe.workload",
    "observe.logs",
    "observe.events",
    "effect.workload"
  ]

  defmodule KubernetesStub do
    import Plug.Conn

    @namespace "bounded-namespace"

    def init(agent), do: agent

    def call(conn, agent) do
      conn = fetch_query_params(conn)
      {:ok, body, conn} = read_body(conn)

      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_params,
        body: body,
        authorized?: get_req_header(conn, "authorization") == ["Bearer static-test-token"]
      }

      Agent.update(agent, &Map.update!(&1, :requests, fn requests -> [request | requests] end))

      if request.authorized? do
        route(conn, agent, request)
      else
        failure(conn, 401, "Unauthorized", "missing bearer token")
      end
    end

    defp route(%{method: "GET", request_path: "/api/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "v1",
        "kind" => "APIResourceList",
        "resources" => [
          resource("pods", "Pod", ~w(get list watch)),
          resource("pods/log", "Pod", ~w(get)),
          resource("events", "Event", ~w(get list))
        ]
      })
    end

    defp route(%{method: "GET", request_path: "/apis/apps/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "apps/v1",
        "kind" => "APIResourceList",
        "resources" => [resource("deployments", "Deployment", ~w(get list patch))]
      })
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods"} = conn,
           agent,
           %{query: %{"watch" => watch}}
         )
         when watch in ["1", "true"] do
      Process.sleep(Agent.get(agent, & &1.watch_delay_ms))
      event = %{"type" => "MODIFIED", "object" => pod("pod-one", "23")}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(event) <> "\n")
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods"} = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "kind" => "PodList",
        "metadata" => %{"resourceVersion" => "22"},
        "items" => [pod("pod-one", "22")]
      })
    end

    defp route(
           %{
             method: "GET",
             request_path: "/api/v1/namespaces/#{@namespace}/pods/pod-one/log"
           } = conn,
           _agent,
           _request
         ) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "line one\nline two\n")
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/events"} = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "kind" => "EventList",
        "metadata" => %{"resourceVersion" => "31"},
        "items" => [
          %{
            "type" => "Warning",
            "reason" => "Unhealthy",
            "message" => "readiness probe failed",
            "involvedObject" => %{
              "kind" => "Pod",
              "name" => "pod-one",
              "uid" => "pod-uid"
            }
          }
        ]
      })
    end

    defp route(
           %{
             method: "GET",
             request_path: "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"
           } = conn,
           agent,
           _request
         ) do
      json(conn, 200, Agent.get(agent, & &1.deployment))
    end

    defp route(
           %{
             method: "PATCH",
             request_path: "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"
           } = conn,
           agent,
           %{body: body}
         ) do
      patch = Jason.decode!(body)

      result =
        Agent.get_and_update(agent, fn state ->
          current = state.deployment

          if get_in(patch, ["metadata", "uid"]) == get_in(current, ["metadata", "uid"]) and
               get_in(patch, ["metadata", "resourceVersion"]) ==
                 get_in(current, ["metadata", "resourceVersion"]) do
            version = current |> get_in(["metadata", "resourceVersion"]) |> String.to_integer()

            updated =
              current
              |> put_in(["metadata", "resourceVersion"], Integer.to_string(version + 1))
              |> update_in(["metadata", "generation"], &(&1 + 1))
              |> put_in(["spec", "replicas"], get_in(patch, ["spec", "replicas"]))
              |> put_in(["status", "readyReplicas"], get_in(patch, ["spec", "replicas"]))
              |> put_in(["status", "availableReplicas"], get_in(patch, ["spec", "replicas"]))

            {{:ok, updated}, %{state | deployment: updated}}
          else
            {{:error, :conflict}, state}
          end
        end)

      case result do
        {:ok, deployment} ->
          Process.sleep(Agent.get(agent, & &1.patch_delay_ms))
          json(conn, 200, deployment)

        {:error, :conflict} ->
          failure(conn, 409, "Conflict", "resourceVersion changed")
      end
    end

    defp route(conn, _agent, _request),
      do: failure(conn, 404, "NotFound", "unexpected Kubernetes fixture route")

    defp resource(name, kind, verbs) do
      %{
        "name" => name,
        "singularName" => "",
        "namespaced" => true,
        "kind" => kind,
        "verbs" => verbs
      }
    end

    defp pod(name, version) do
      %{
        "apiVersion" => "v1",
        "kind" => "Pod",
        "metadata" => %{
          "name" => name,
          "uid" => "pod-uid",
          "resourceVersion" => version
        },
        "status" => %{"phase" => "Running", "nodeName" => "node-one"}
      }
    end

    defp failure(conn, status, reason, message) do
      json(conn, status, %{
        "apiVersion" => "v1",
        "kind" => "Status",
        "status" => "Failure",
        "reason" => reason,
        "message" => message,
        "code" => status
      })
    end

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    deployment = %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "app",
        "namespace" => @namespace,
        "uid" => "deployment-uid",
        "resourceVersion" => "17",
        "generation" => 7
      },
      "spec" => %{"replicas" => 1},
      "status" => %{
        "readyReplicas" => 1,
        "availableReplicas" => 1,
        "observedGeneration" => 7
      }
    }

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{requests: [], deployment: deployment, watch_delay_ms: 0, patch_delay_ms: 0}
         end}
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {KubernetesStub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin = Accounts.bootstrap!("kubernetes-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("kubernetes-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "kubernetes-api",
        :target,
        "kubernetes-api",
        configuration(),
        %{"kubeconfig" => kubeconfig(endpoint)},
        actor: admin
      )

    checked =
      Providers.check_provider!(provider.id, provider.revision, %{"endpoint" => endpoint},
        actor: admin
      )

    assert checked.check_status == :passed,
           "Kubernetes fixture check failed: #{checked.check_category}: #{checked.check_message}"

    provider = Providers.enable_provider!(checked, checked.revision, actor: admin)

    target =
      Targets.create_target!("cluster-one", "cluster", "kubernetes", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "kubernetes-api",
        "kubernetes",
        "api",
        endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      agent: agent,
      endpoint: endpoint
    }
  end

  test "public Provider path exposes bounded namespace operations and observations", context do
    assert %Target.Capabilities{observations: observations, effects: [effect]} =
             Providers.target_capabilities!(
               context.provider.id,
               context.provider.revision,
               %{},
               actor: context.operator
             )

    assert Enum.map(observations, & &1.operation) == [
             "kubernetes.pods.list",
             "kubernetes.deployment.inspect",
             "kubernetes.pod.logs",
             "kubernetes.events.list",
             "kubernetes.pods.watch"
           ]

    tools = Map.new(observations, &{&1.operation, &1})
    deployment_tool = tools["kubernetes.deployment.inspect"]

    assert Map.keys(deployment_tool.verification_schema["properties"]) == ["replicas"]
    assert deployment_tool.verification_schema["required"] == ["replicas"]
    assert_schema_accepts!(deployment_tool.verification_schema, %{"replicas" => 1})

    assert_schema_rejects!(deployment_tool.verification_schema, %{
      "replicas" => 1,
      "ready_replicas" => 1
    })

    assert_schema_rejects!(deployment_tool.verification_schema, %{
      "replicas" => 1,
      "available_replicas" => 1
    })

    assert effect.operation == "kubernetes.deployment.scale"

    assert effect.evidence_requirements == [
             %Target.EvidenceRequirement{
               parameter: "expected_uid",
               fact: "uid",
               observation: "kubernetes.deployment.inspect"
             },
             %Target.EvidenceRequirement{
               parameter: "expected_resource_version",
               fact: "resource_version",
               observation: "kubernetes.deployment.inspect"
             }
           ]

    pods = observe!(context, "observe.workloads", "kubernetes.pods.list", %{}, %{"limit" => 10})
    assert_schema_accepts!(tools["kubernetes.pods.list"].output_schema, pods.facts)
    assert pods.facts["resource_version"] == "22"
    assert [%{"name" => "pod-one", "phase" => "Running"}] = pods.facts["pods"]

    logs =
      observe!(
        context,
        "observe.logs",
        "kubernetes.pod.logs",
        %{"name" => "pod-one", "container" => "app"},
        %{"tail_lines" => 20, "limit_bytes" => 2_048}
      )

    assert_schema_accepts!(tools["kubernetes.pod.logs"].output_schema, logs.facts)
    assert logs.facts["logs"] == "line one\nline two\n"

    events =
      observe!(context, "observe.events", "kubernetes.events.list", %{}, %{"limit" => 10})

    assert_schema_accepts!(tools["kubernetes.events.list"].output_schema, events.facts)

    assert [%{"reason" => "Unhealthy", "regarding_name" => "pod-one"}] =
             events.facts["events"]

    watch =
      observe!(context, "observe.workloads", "kubernetes.pods.watch", %{}, %{
        "resource_version" => "22",
        "timeout_seconds" => 5,
        "max_events" => 1,
        "labels" => %{"app" => "fixture"}
      })

    assert_schema_accepts!(tools["kubernetes.pods.watch"].output_schema, watch.facts)

    assert [%{"type" => "MODIFIED", "object" => %{"resource_version" => "23"}}] =
             watch.facts["events"]

    deployment =
      observe!(
        context,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{}
      )

    assert_schema_accepts!(deployment_tool.output_schema, deployment.facts)

    assert Enum.all?(requests(context), fn request ->
             request.authorized? and
               (request.path in ["/api/v1", "/apis/apps/v1"] or
                  String.contains?(request.path, "/namespaces/#{@namespace}/"))
           end)

    log_request = Enum.find(requests(context), &String.ends_with?(&1.path, "/log"))
    assert log_request.query["limitBytes"] == "2048"
    assert log_request.query["tailLines"] == "20"

    watch_request = Enum.find(requests(context), &(&1.query["watch"] in ["1", "true"]))
    assert watch_request.query["labelSelector"] == "app=fixture"
  end

  test "approved scale is preconditioned and followed by fresh verification", context do
    before =
      observe!(
        context,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{}
      )

    effect = scale_request(context, before.facts["uid"], before.facts["resource_version"], 2)
    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "18"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    verification =
      policy_request(
        context,
        :verification,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{},
        %{"replicas" => 2}
      )

    verification_clearance =
      Targets.clear_target_request!(verification, actor: context.operator)

    assert %Target.Verification{status: :verified, facts: %{"resource_version" => "18"}} =
             Targets.dispatch_target_verification!(verification_clearance, %{},
               actor: context.operator
             )

    request_count = length(requests(context))

    invalid_verification =
      policy_request(
        context,
        :verification,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{},
        %{"replicas" => 2, "ready_replicas" => 2}
      )

    invalid_clearance =
      Targets.clear_target_request!(invalid_verification, actor: context.operator)

    assert {:error, _error} =
             Targets.dispatch_target_verification(invalid_clearance, %{}, actor: context.operator)

    assert length(requests(context)) == request_count

    stale = scale_request(context, before.facts["uid"], before.facts["resource_version"], 0)
    stale_clearance = Targets.clear_target_request!(stale, actor: context.operator)

    assert %Target.EffectResult{
             status: :failed,
             details: %{"category" => "conflict"}
           } =
             Targets.dispatch_target_effect!(stale_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    current =
      observe!(
        context,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{}
      )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})

    lost_response =
      scale_request(context, current.facts["uid"], current.facts["resource_version"], 3)

    lost_clearance = Targets.clear_target_request!(lost_response, actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(lost_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 0})

    reconciled =
      policy_request(
        context,
        :verification,
        "observe.workload",
        "kubernetes.deployment.inspect",
        %{"name" => "app"},
        %{},
        %{"replicas" => 3}
      )

    reconciled_clearance = Targets.clear_target_request!(reconciled, actor: context.operator)

    assert %Target.Verification{status: :verified, facts: %{"resource_version" => "19"}} =
             Targets.dispatch_target_verification!(reconciled_clearance, %{},
               actor: context.operator
             )

    patch_requests = Enum.filter(requests(context), &(&1.method == "PATCH"))
    assert length(patch_requests) == 3
  end

  test "namespace escape stops locally and an interrupted watch stays bounded", context do
    request_count = length(requests(context))

    escaped =
      policy_request(
        context,
        :observation,
        "observe.workloads",
        "kubernetes.pods.list",
        %{"namespace" => "kube-system"},
        %{"limit" => 10}
      )

    escaped_clearance = Targets.clear_target_request!(escaped, actor: context.operator)

    assert {:error, _error} =
             Targets.dispatch_target_observation(escaped_clearance, %{}, actor: context.operator)

    assert length(requests(context)) == request_count

    wrong_method =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "wrong Kubernetes endpoint",
        "kubernetes",
        "api",
        "https://127.0.0.1:1",
        context.provider.revision,
        200,
        ["observe.workloads"],
        actor: context.admin
      )

    wrong_context = %{context | method: wrong_method}

    wrong_endpoint =
      policy_request(
        wrong_context,
        :observation,
        "observe.workloads",
        "kubernetes.pods.list",
        %{},
        %{"limit" => 1}
      )

    wrong_clearance = Targets.clear_target_request!(wrong_endpoint, actor: context.operator)

    assert {:error, _error} =
             Targets.dispatch_target_observation(wrong_clearance, %{}, actor: context.operator)

    assert length(requests(context)) == request_count

    Agent.update(context.agent, &%{&1 | watch_delay_ms: 2_000})

    watch =
      policy_request(
        context,
        :observation,
        "observe.workloads",
        "kubernetes.pods.watch",
        %{},
        %{"resource_version" => "22", "timeout_seconds" => 5, "max_events" => 1}
      )

    watch_clearance = Targets.clear_target_request!(watch, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_observation(watch_clearance, %{}, actor: context.operator)

    assert target_error(error).category == :timeout

    assert Enum.any?(requests(context), fn request ->
             request.path == "/api/v1/namespaces/#{@namespace}/pods" and
               request.query["watch"] in ["1", "true"]
           end)

    refute Enum.any?(requests(context), &String.contains?(&1.path, "kube-system"))
  end

  test "kubeconfig cannot execute helpers, read credential paths or disable TLS", context do
    unsafe_exec =
      String.replace(
        kubeconfig(context.endpoint),
        "token: static-test-token",
        "exec:\n          command: cloud-login"
      )

    assert {:error, :invalid_configuration} =
             API.build(configuration(), %{"kubeconfig" => unsafe_exec})

    path_based =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      certificate-authority: /etc/ca.pem"
      )

    assert {:error, :invalid_configuration} =
             API.build(configuration(), %{"kubeconfig" => path_based})

    insecure =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      insecure-skip-tls-verify: true"
      )

    assert {:error, :invalid_configuration} =
             API.build(configuration(), %{"kubeconfig" => insecure})
  end

  defp observe!(context, capability, operation, selectors, parameters) do
    request =
      policy_request(context, :observation, capability, operation, selectors, parameters)

    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
  end

  defp scale_request(context, uid, resource_version, replicas) do
    policy_request(
      context,
      :effect,
      "effect.workload",
      "kubernetes.deployment.scale",
      %{"name" => "app"},
      %{
        "replicas" => replicas,
        "expected_uid" => uid,
        "expected_resource_version" => resource_version
      }
    )
  end

  defp policy_request(
         context,
         kind,
         capability,
         operation,
         selectors,
         parameters,
         expected \\ %{}
       ) do
    struct!(PolicyRequest,
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: capability,
      operation: operation,
      selectors: selectors,
      parameters: parameters,
      operation_id:
        if(kind in [:effect, :verification], do: "operation-#{System.unique_integer()}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{System.unique_integer()}"),
      expected: expected
    )
  end

  defp configuration do
    %{"namespace" => @namespace, "request_timeout_ms" => 500}
  end

  defp kubeconfig(endpoint) do
    certificate =
      "test/support/certs/kubernetes_fixture_ca.pem"
      |> File.read!()
      |> Base.encode64()

    """
    apiVersion: v1
    kind: Config
    clusters:
      - name: target
        cluster:
          server: #{endpoint}
          certificate-authority-data: #{certificate}
    users:
      - name: operator
        user:
          token: static-test-token
    contexts:
      - name: target
        context:
          cluster: target
          user: operator
          namespace: #{@namespace}
    current-context: target
    """
  end

  defp requests(context),
    do: Agent.get(context.agent, &Enum.reverse(&1.requests))

  defp assert_schema_accepts!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(facts, root, cast: false)
  end

  defp assert_schema_rejects!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:error, _error} = JSV.validate(facts, root, cast: false)
  end

  defp target_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Target.Error{} = error -> error
      %{errors: nested} -> target_error(%{errors: nested})
      _error -> nil
    end)
  end

  defp target_error(_error), do: nil
end
