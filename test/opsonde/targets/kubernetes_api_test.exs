defmodule Opsonde.Targets.KubernetesAPITest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.Kubernetes
  alias Opsonde.Targets.TargetRequest.Request

  @password "correct horse battery staple"
  @namespace "bounded-namespace"
  @capabilities ["request.kubernetes.observe", "request.kubernetes.effect"]

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
        content_type: get_req_header(conn, "content-type"),
        accept: get_req_header(conn, "accept"),
        authorized?: get_req_header(conn, "authorization") == ["Bearer static-test-token"]
      }

      Agent.update(agent, &Map.update!(&1, :requests, fn requests -> [request | requests] end))

      if request.authorized? do
        route(conn, agent, request)
      else
        failure(conn, 401, "Unauthorized", "missing bearer token")
      end
    end

    defp route(%{method: "GET", request_path: "/api"} = conn, _agent, _request),
      do: json(conn, 200, %{"kind" => "APIVersions", "versions" => ["v1"]})

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

    defp route(%{method: "GET", request_path: "/apis/example.com/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "example.com/v1",
        "kind" => "APIResourceList",
        "resources" => [resource("widgets", "Widget", ~w(get list create update patch))]
      })
    end

    defp route(
           %{
             method: "POST",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets"
           } = conn,
           agent,
           %{body: body}
         ) do
      widget = Jason.decode!(body)
      Agent.update(agent, &Map.put(&1, :created_widget, widget))
      json(conn, 201, widget)
    end

    defp route(
           %{
             method: "PUT",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           %{body: body}
         ) do
      widget = Jason.decode!(body)
      Agent.update(agent, &Map.put(&1, :widget, widget))
      json(conn, 200, widget)
    end

    defp route(
           %{
             method: "GET",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           _request
         ) do
      json(conn, 200, Agent.get(agent, & &1.widget))
    end

    defp route(
           %{
             method: "PATCH",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           %{body: body}
         ) do
      patch = Jason.decode!(body)

      widget =
        Agent.get_and_update(agent, fn state ->
          current = state.widget

          updated =
            current
            |> put_in(["metadata", "resourceVersion"], "8")
            |> put_in(["spec", "mode"], get_in(patch, ["spec", "mode"]))

          {updated, %{state | widget: updated}}
        end)

      json(conn, 200, widget)
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
             request_path: "/api/v1/namespaces/#{@namespace}/pods/pod-one"
           } = conn,
           _agent,
           _request
         ) do
      json(conn, 200, pod("pod-one", "22"))
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

    defp route(
           %{
             method: "PATCH",
             request_path:
               "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
           } = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{"metadata" => %{"resourceVersion" => "9"}, "status" => %{"ready" => true}})
    end

    defp route(
           %{
             method: "GET",
             request_path:
               "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
           } = conn,
           _agent,
           _request
         ) do
      conn
      |> put_resp_content_type("application/yaml")
      |> send_resp(200, "status:\n  ready: true\n")
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/pod-one/log"} =
             conn,
           _agent,
           _request
         ),
         do:
           conn
           |> put_resp_content_type("text/plain")
           |> send_resp(200, String.duplicate("complete log line\n", 700))

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/huge/log"} = conn,
           _agent,
           _request
         ),
         do:
           conn
           |> put_resp_content_type("text/plain")
           |> send_resp(200, String.duplicate("x", 70_000))

    defp route(
           %{
             method: "DELETE",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets"
           } = conn,
           _agent,
           _request
         ),
         do: json(conn, 200, %{"kind" => "Status", "status" => "Success"})

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/numeric/log"} =
             conn,
           _agent,
           _request
         ),
         do: conn |> put_resp_content_type("text/plain") |> send_resp(200, "123\n")

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

    widget = %{
      "apiVersion" => "example.com/v1",
      "kind" => "Widget",
      "metadata" => %{
        "name" => "widget-one",
        "namespace" => @namespace,
        "resourceVersion" => "7"
      },
      "spec" => %{"mode" => "idle"}
    }

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             deployment: deployment,
             widget: widget,
             created_widget: nil,
             patch_delay_ms: 0
           }
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

  test "generic API request reaches a dynamically discovered custom resource", context do
    parameters = %{
      "method" => "GET",
      "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
    }

    observation =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters)

    assert get_in(observation.facts, ["response", "spec", "mode"]) == "idle"

    request =
      target_request(
        context,
        :effect,
        "request.kubernetes.effect",
        "request.execute",
        %{},
        Map.merge(parameters, %{
          "method" => "PATCH",
          "content_type" => "application/merge-patch+json",
          "body" => Jason.encode!(%{"spec" => %{"mode" => "active"}})
        })
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "8"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert get_in(
             observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters).facts,
             ["response", "spec", "mode"]
           ) == "active"

    assert Enum.any?(requests(context), &(&1.path == parameters["path"]))
  end

  test "exact HTTP Method carries CRD subresource apply and complete YAML response", context do
    path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
    body = "apiVersion: example.com/v1\nkind: Widget\nstatus:\n  ready: true\n"

    request =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "query" => %{"fieldManager" => "opsonde-test", "force" => "true"},
        "content_type" => "application/apply-patch+yaml",
        "body" => body
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "9"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    sent = Enum.find(requests(context), &(&1.method == "PATCH"))
    assert sent.path == path
    assert sent.body == body
    assert sent.content_type == ["application/apply-patch+yaml"]
    assert sent.query == %{"fieldManager" => "opsonde-test", "force" => "true"}

    result =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => path,
        "accept" => "application/json;as=Table;g=meta.k8s.io;v=v1, application/yaml"
      })

    assert result.facts["response"] == "status:\n  ready: true\n"
    assert result.facts["content_type"] == "application/yaml"

    assert Enum.any?(
             requests(context),
             &(&1.accept == ["application/json;as=Table;g=meta.k8s.io;v=v1, application/yaml"])
           )
  end

  test "HTTP Method carries JSON patch, complete text and DELETE collection", context do
    patch_body = ~s([{"op":"replace","path":"/status/ready","value":true}])

    patch =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status",
        "content_type" => "application/json-patch+json",
        "body" => patch_body
      })

    clearance = Targets.clear_target_request!(patch, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Enum.any?(
             requests(context),
             &(&1.body == patch_body and &1.content_type == ["application/json-patch+json"])
           )

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one/log",
        "query" => %{"tailLines" => "700", "timestamps" => "true"},
        "accept" => "text/plain"
      })

    assert observed.facts["response"] == String.duplicate("complete log line\n", 700)
    assert observed.facts["http_status"] == 200

    numeric =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/numeric/log",
        "accept" => "text/plain"
      })

    assert numeric.facts["response"] == "123\n"

    delete_body = ~s({"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"Background"})

    delete =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "DELETE",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "query" => %{"labelSelector" => "app=disposable"},
        "body" => delete_body
      })

    clearance = Targets.clear_target_request!(delete, actor: context.operator)

    assert %Target.EffectResult{status: :applied, details: %{"http_status" => 200}} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    sent = Enum.find(requests(context), &(&1.method == "DELETE"))
    assert sent.body == delete_body
    assert sent.query == %{"labelSelector" => "app=disposable"}
  end

  test "HTTP Method rejects path substitution and unsafe inputs before I/O", context do
    before = length(requests(context))
    path = "/api/v1/namespaces/#{@namespace}/pods"

    for parameters <- [
          %{"method" => "GET", "path" => "https://other.example#{path}"},
          %{"method" => "GET", "path" => "//other.example#{path}"},
          %{"method" => "GET", "path" => path <> "/../nodes"},
          %{"method" => "GET", "path" => path <> "/%2e%2e/nodes"},
          %{"method" => "GET", "path" => path <> "?namespace=other"},
          %{"method" => "GET", "path" => path, "query" => %{"watch" => "T"}},
          %{
            "method" => "GET",
            "path" => path <> "/pod-one/exec",
            "query" => %{"command" => "delete"}
          },
          %{
            "method" => "GET",
            "path" => path,
            "query" => %{"labelSelector" => String.duplicate("x", 2_049)}
          },
          %{
            "method" => "GET",
            "path" => path,
            "accept" => "application/json\r\nAuthorization: injected"
          }
        ] do
      request =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          parameters
        )

      assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    end

    bad_body =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "body" => "{broken"
      })

    assert {:error, _} = Targets.clear_target_request(bad_body, actor: context.operator)
    assert length(requests(context)) == before

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/huge/log",
          "accept" => "text/plain"
        }
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

    assert Exception.message(error) =~ "inline size limit"
  end

  test "one generic Method observes built-in resources without fixed capabilities", context do
    assert %Target.Capabilities{observations: [observation], effects: [effect]} =
             Providers.target_capabilities!(
               context.provider.id,
               context.provider.revision,
               %{},
               actor: context.operator
             )

    assert observation.capability == "request.kubernetes.observe"
    assert observation.operation == "request.observe"
    assert effect.capability == "request.kubernetes.effect"
    assert effect.operation == "request.execute"

    pod =
      observe!(context, observation.capability, observation.operation, %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
        "query" => %{"pretty" => "true"}
      })

    assert get_in(pod.facts, ["response", "metadata", "name"]) == "pod-one"
    assert_schema_accepts!(observation.output_schema, pod.facts)

    for {resource, expected_kind} <- [
          {"pods", "PodList"},
          {"events", "EventList"}
        ] do
      result =
        observe!(context, observation.capability, observation.operation, %{}, %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/#{resource}"
        })

      assert get_in(result.facts, ["response", "kind"]) == expected_kind
    end

    deployment = deployment_observation!(context)
    assert get_in(deployment, ["response", "spec", "replicas"]) == 1

    assert Enum.all?(requests(context), fn request ->
             request.authorized? and
               (request.path == "/api" or
                  String.contains?(request.path, "/namespaces/#{@namespace}/"))
           end)
  end

  test "generic observations reject changed scope and malformed query before dispatch",
       context do
    request_count = length(requests(context))

    for {path, query} <- [
          {"/api/v1/namespaces/other/pods", %{}},
          {"/api/v1/namespaces/#{@namespace}/pods", %{"labelSelector" => 42}}
        ] do
      request =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          %{
            "method" => "GET",
            "path" => path,
            "query" => query
          }
        )

      assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    end

    assert length(requests(context)) == request_count

    {:ok, state} =
      Kubernetes.build(configuration(), %{"kubeconfig" => kubeconfig(context.endpoint)})

    wrong_endpoint = %{
      capability: "request.kubernetes.observe",
      operation: "request.observe",
      connection: %{endpoint: "https://127.0.0.1:1"},
      selectors: %{},
      parameters: %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one"
      }
    }

    assert {:error, :failed, _message} = Kubernetes.observe(state, wrong_endpoint, %{})

    assert length(requests(context)) == request_count
  end

  test "Kubernetes Method rejects an unrelated namespace parameter before dispatch", context do
    request_count = length(requests(context))

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
          "namespace" => "other-namespace"
        }
      )

    assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    assert length(requests(context)) == request_count
  end

  test "Kubernetes read rejects a body that the API request would ignore", context do
    request_count = length(requests(context))

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
          "body" => Jason.encode!(%{"metadata" => %{"namespace" => "other-namespace"}})
        }
      )

    assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    assert length(requests(context)) == request_count
  end

  test "generic write preserves conflict and unknown outcomes with independent observation",
       context do
    before = deployment_observation!(context)["response"]
    effect = deployment_patch(context, before, 2)
    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "18"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    fresh = deployment_observation!(context)["response"]
    assert get_in(fresh, ["spec", "replicas"]) == 2

    verification =
      target_request(
        context,
        :verification,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        deployment_get_parameters(),
        %{"response" => fresh}
      )

    verified = Targets.clear_target_request!(verification, actor: context.operator)

    assert %Target.Verification{status: :verified} =
             Targets.dispatch_target_verification!(verified, %{}, actor: context.operator)

    stale =
      Targets.clear_target_request!(deployment_patch(context, before, 0), actor: context.operator)

    assert %Target.EffectResult{status: :failed, details: %{"category" => "conflict"}} =
             Targets.dispatch_target_effect!(stale, %{},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})

    lost =
      Targets.clear_target_request!(deployment_patch(context, fresh, 3), actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(lost, %{},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 0})
    reconciled = deployment_observation!(context)["response"]
    assert get_in(reconciled, ["spec", "replicas"]) == 3
    assert length(Enum.filter(requests(context), &(&1.method == "PATCH"))) == 3
  end

  test "HTTP effect cancellation before and after send preserves uncertainty without replay",
       context do
    before = deployment_observation!(context)["response"]
    request = deployment_patch(context, before, 2)
    clearance = Targets.clear_target_request!(request, actor: context.operator)
    count = length(requests(context))

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert length(requests(context)) == count

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})
    cancelled = fn -> Enum.any?(requests(context), &(&1.method == "PATCH")) end

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(clearance, %{cancelled?: cancelled},
               actor: context.operator,
               authorize?: false
             )

    assert length(Enum.filter(requests(context), &(&1.method == "PATCH"))) == 1
    Agent.update(context.agent, &%{&1 | patch_delay_ms: 0})
    assert get_in(deployment_observation!(context), ["response", "spec", "replicas"]) == 2
  end

  test "generic create and update cannot select a different namespace", context do
    {:ok, state} =
      Kubernetes.build(configuration(), %{"kubeconfig" => kubeconfig(context.endpoint)})

    count = length(requests(context))

    for method <- ["POST", "PUT"] do
      request = %{
        capability: "request.kubernetes.effect",
        operation: "request.execute",
        connection: %{endpoint: context.endpoint},
        selectors: %{},
        parameters: %{
          "method" => method,
          "path" => "/apis/apps/v1/namespaces/kube-system/deployments/app",
          "body" =>
            Jason.encode!(%{
              "apiVersion" => "apps/v1",
              "kind" => "Deployment",
              "metadata" => %{"name" => "app", "namespace" => "kube-system"}
            })
        }
      }

      assert {:error, :failed, _message} = Kubernetes.effect(state, request, %{})
    end

    assert length(requests(context)) == count
  end

  test "generic create and update use the configured namespace", context do
    created = %{
      "apiVersion" => "example.com/v1",
      "kind" => "Widget",
      "metadata" => %{"name" => "widget-two", "namespace" => @namespace},
      "spec" => %{"mode" => "active"}
    }

    create =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "POST",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "body" => Jason.encode!(created)
      })

    clearance = Targets.clear_target_request!(create, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.created_widget) == created

    previous =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
      }).facts["response"]

    updated = put_in(previous, ["spec", "mode"], "updated")

    update =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PUT",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one",
        "body" => Jason.encode!(updated)
      })

    clearance = Targets.clear_target_request!(update, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.widget) == updated

    assert Enum.all?(
             Enum.filter(requests(context), &(&1.method in ["POST", "PUT"])),
             fn request ->
               String.contains?(request.path, "/namespaces/#{@namespace}/")
             end
           )
  end

  test "kubeconfig cannot execute helpers, read credential paths or disable TLS", context do
    unsafe_exec =
      String.replace(
        kubeconfig(context.endpoint),
        "token: static-test-token",
        "exec:\n          command: cloud-login"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => unsafe_exec})

    path_based =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      certificate-authority: /etc/ca.pem"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => path_based})

    insecure =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      insecure-skip-tls-verify: true"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => insecure})
  end

  defp observe!(context, capability, operation, selectors, parameters) do
    request =
      target_request(context, :observation, capability, operation, selectors, parameters)

    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
  end

  defp deployment_get_parameters do
    %{"method" => "GET", "path" => "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"}
  end

  defp deployment_observation!(context) do
    observe!(
      context,
      "request.kubernetes.observe",
      "request.observe",
      %{},
      deployment_get_parameters()
    ).facts
  end

  defp deployment_patch(context, observed, replicas) do
    target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
      "method" => "PATCH",
      "path" => "/apis/apps/v1/namespaces/#{@namespace}/deployments/app",
      "content_type" => "application/merge-patch+json",
      "body" =>
        Jason.encode!(%{
          "metadata" => %{
            "uid" => get_in(observed, ["metadata", "uid"]),
            "resourceVersion" => get_in(observed, ["metadata", "resourceVersion"])
          },
          "spec" => %{"replicas" => replicas}
        })
    })
  end

  defp target_request(
         context,
         kind,
         capability,
         operation,
         selectors,
         parameters,
         expected \\ %{}
       ) do
    struct!(Request,
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
end
