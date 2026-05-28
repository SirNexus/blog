---
slug: istio-pod-to-pod-mtls
title: Enabling pod to pod mTLS in Istio
authors: aidancarson
tags: [Istio, ServiceEntry, pod, mTLS, strict, authentication]
# Display h2 to h5 headings
toc_min_heading_level: 2
toc_max_heading_level: 5
---

# Enabling pod to pod mTLS in Istio

Istio handles mTLS beautifully when you're routing traffic through Kubernetes services. You flip on strict mode, everything keeps working, and you go home happy. But the moment you need to address pods *directly by IP* -- say, for cross-cluster communication over a flat network -- things get weird. Strict mTLS breaks in ways that are surprisingly hard to debug.

This post walks through that exact scenario: how to get Istio's mTLS working when your traffic targets pod IPs instead of service names.

## When would you need this?

If you're addressing pods by IP rather than by service name, this post is for you. Common scenarios:

- **Multi-cluster with a flat network** -- pods are routable by IP across clusters, but you don't have shared DNS or a common service registry. You can't just `curl my-service.namespace` because that service doesn't exist in the calling cluster.
- **ServiceEntry + WorkloadEntry patterns** -- you're grouping remote pod IPs under a logical hostname using Istio primitives, essentially building your own cross-cluster service discovery.
- **Migrating workloads off-cluster** -- VMs or legacy pods that need to participate in the mesh but aren't behind a Kubernetes Service.

In all these cases, Istio doesn't have a native Service object to associate with the destination pod. And that's where strict mTLS falls apart, because Istio relies on that association to know the destination's identity.

The short version: your WorkloadEntry needs a `serviceAccount` field, and your ServiceEntry needs the correct `subjectAltNames`. Keep reading for the full debugging story.

<!-- truncate -->

## The setup

Here's the situation. I have two clusters, both running Istio, networked together so that pod IPs are directly routable between them. There's no shared service registry -- a pod in cluster1 can't just `curl echo.echo` and hit a pod in cluster2. So I need a way to address these remote pods, ideally under a single logical hostname.

The Istio primitives for this are **ServiceEntry** (to define the hostname) and **WorkloadEntry** (to register individual pod IPs as endpoints behind it). It's essentially building your own service abstraction on top of raw pod IPs. Here's what my configuration looked like:

ServiceEntry:
```yaml
apiVersion: v1
items:
  - apiVersion: networking.istio.io/v1
    kind: ServiceEntry
    metadata:
      creationTimestamp: "2025-04-29T17:01:04Z"
      generation: 7
      name: global-curl-global-echo
      namespace: curl
      resourceVersion: "7068"
      uid: 9c26a814-e852-4903-81a9-9213987236a0
    spec:
      hosts:
        - global-echo
      location: MESH_INTERNAL
      ports:
        - name: http
          number: 80
          protocol: HTTP
          targetPort: 8080
      resolution: STATIC
      subjectAltNames:
        - spiffe://cluster.local/ns/echo/sa/default
        - spiffe://cluster.local/ns/echo/sa/default
      workloadSelector:
        labels:
          global-service: global-echo
    status:
      addresses:
        - host: global-echo
          value: 240.240.0.1
        - host: global-echo
          value: 2001:2::1
kind: List
metadata:
  resourceVersion: ""
```
WorkloadEntry:
```
NAME                              AGE     ADDRESS
global-echo-cluster1-10.4.2.45    4m58s   10.4.2.45
global-echo-cluster2-10.6.1.212   27m     10.6.1.212
```


```yaml
apiVersion: v1
items:
  - apiVersion: networking.istio.io/v1
    kind: WorkloadEntry
    metadata:
      creationTimestamp: "2025-04-29T17:24:24Z"
      generation: 2
      labels:
        global-service: global-echo
      name: global-echo-cluster1-10.4.2.45
      namespace: curl
      resourceVersion: "7188"
      uid: d8c0a5da-aab8-4338-b890-b597a7883f47
    spec:
      address: 10.4.2.45
      labels:
        global-service: global-echo
  - apiVersion: networking.istio.io/v1
    kind: WorkloadEntry
    metadata:
      creationTimestamp: "2025-04-29T17:01:43Z"
      generation: 4
      labels:
        global-service: global-echo
      name: global-echo-cluster2-10.6.1.212
      namespace: curl
      resourceVersion: "7189"
      uid: 72ff1595-e098-4eb2-9f84-f251d3c8faf4
    spec:
      address: 10.6.1.212
      labels:
        global-service: global-echo
kind: List
metadata:
  resourceVersion: ""

```

So we have a hostname `global-echo` backed by two pods, each living in a different cluster. Behind the scenes, both pods are running simple echo servers. If you want to reproduce this, here's the deployment I used:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: echo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args:
            - -text={{ .CurCluster }}
            - -listen=:8080
          resources:
            requests:
              cpu: "100m"
              memory: "100Mi"
            limits:
              cpu: "100m"
              memory: "100Mi"
```

And it works great -- traffic load-balances across both clusters:

```
for i in {1..10}; do curl global-echo; done
cluster1
cluster1
cluster1
cluster1
cluster2
cluster2
cluster2
cluster1
cluster1
cluster2
```

Everything's looking good so far. But we haven't verified security yet.

## The problem: enabling strict mTLS breaks everything

Networking is working, Istio is generating the right Envoy config, and our global hostname happily routes to both clusters. But is traffic actually encrypted? Let's enforce it by turning on strict mTLS:

``` bash
$ kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: prod-istio-system # The namespace of our istio installation
spec:
  mtls:
    mode: STRICT
EOF
```

And now let's see if things still work:

```bash
$ for i in {1..10}; do curl global-echo; done
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

Completely broken. And here's the kicker -- this tells us something important about what was happening *before*. Our traffic was never actually using mTLS. Istio was in PERMISSIVE mode, so it was happily sending everything as plaintext. We thought we had encryption, but we didn't. That's precisely why strict mode is worth enforcing -- it surfaces these misconfigurations instead of silently downgrading your security.

So what's going wrong? When you route through a normal Kubernetes Service, Istio handles mTLS automatically. But we're not doing that -- we're routing to pod IPs. Let's dig in.

## Debugging: it's a pod-IP problem, not an mTLS problem

First, let's confirm the issue is specific to pod-IP routing. The local echo pod in cluster1 has IP `10.4.2.45`:

```bash
$ curl 10.4.2.45
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

Broken -- but that's the same pod IP our ServiceEntry resolves to, so no surprise there.

Now let's try the same pod through its regular Kubernetes Service:

```bash
$ curl echo.echo
cluster1
```

That works. Same pod, same sidecar, same strict mTLS policy -- but it works because Istio *knows* this pod's identity through the Service object.

What about the service's ClusterIP directly?

```bash
$ kubectl get svc -n echo
NAME            TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
echo            ClusterIP   10.5.113.88   <none>        80/TCP    48m
```

```bash
$ curl 10.5.113.88
cluster1
```

Also works. Istio intercepts the ClusterIP traffic and still associates it with the known service.

So the pattern is clear: **Istio handles mTLS correctly when it can associate traffic with a Kubernetes Service** (by DNS name or ClusterIP). But when traffic goes to a bare pod IP through a ServiceEntry + WorkloadEntry, Istio doesn't have enough information to establish identity -- and mTLS fails. This is the fundamental challenge of the pod-IP approach.

This sent me back to the [Istio WorkloadEntry docs](https://istio.io/latest/docs/reference/config/networking/workload-entry/), where this comment caught my eye:

```
...
  # use of the service account indicates that the workload has a
  # sidecar proxy bootstrapped with this service account. Pods with
  # sidecars will automatically communicate with the workload using
  # istio mutual TLS.
  serviceAccount: details-legacy
```

There it is. Istio needs a `serviceAccount` on the WorkloadEntry to know that the destination has a sidecar and to initiate mTLS. Without it, Istio doesn't know what identity to expect from the remote pod. Let's add it:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  labels:
    global-service: global-echo
  name: global-echo-cluster1-10.4.2.45
  namespace: curl
spec:
  address: 10.4.2.45
  labels:
    global-service: global-echo
  serviceAccount: client # <-----   Added this
---
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  labels:
    global-service: global-echo
  name: global-echo-cluster2-10.6.1.212
  namespace: curl
spec:
  address: 10.6.1.212
  labels:
    global-service: global-echo
  serviceAccount: client # <-----   Added this
```

Now let's try again:

```bash
$ curl global-echo
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end
```

Progress! The error changed. Istio is now *attempting* mTLS (good!) but the certificate verification is failing (not good). Time to look at the Envoy logs.

## Diving into the Envoy logs

On a successful request (`curl 10.5.113.88` -- the ClusterIP that works), the client sidecar logs show:

```
2025-04-29T17:44:56.975202Z	debug	envoy filter external/envoy/source/extensions/filters/listener/original_dst/original_dst.cc:69	original_dst: set destination to 10.5.113.88:80	thread=28
2025-04-29T17:44:56.975404Z	debug	envoy filter external/envoy/source/extensions/filters/listener/http_inspector/http_inspector.cc:139	http inspector: set application protocol to http/1.1	thread=28
2025-04-29T17:44:56.975558Z	debug	envoy conn_handler external/envoy/source/common/listener_manager/active_tcp_listener.cc:160	[Tags: "ConnectionId":"192"] new connection from 10.4.2.55:49952	thread=28
2025-04-29T17:44:56.975643Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:393	[Tags: "ConnectionId":"192"] new stream	thread=28
2025-04-29T17:44:56.975821Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1183	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] request headers complete (end_stream=true):
':authority', '10.5.113.88'
':path', '/'
':method', 'GET'
'user-agent', 'curl/8.7.1'
'accept', '*/*'
	thread=28
2025-04-29T17:44:56.975840Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1166	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] request end stream timestamp recorded	thread=28
2025-04-29T17:44:56.975870Z	debug	envoy connection external/envoy/source/common/network/connection_impl.h:98	[Tags: "ConnectionId":"192"] current connecting state: false	thread=28
2025-04-29T17:44:56.975922Z	debug	envoy filter source/extensions/filters/http/alpn/alpn_filter.cc:92	override with 3 ALPNs	thread=28
2025-04-29T17:44:56.975938Z	debug	envoy router external/envoy/source/common/router/router.cc:527	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] cluster 'outbound|80||echo.echo.svc.cluster.local' match for URL '/'	thread=28
2025-04-29T17:44:56.975979Z	debug	envoy router external/envoy/source/common/router/router.cc:756	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] router decoding headers:
':authority', '10.5.113.88'
':path', '/'
':method', 'GET'
':scheme', 'http'
'user-agent', 'curl/8.7.1'
'accept', '*/*'
'x-forwarded-proto', 'http'
'x-request-id', '79f4055e-4122-4096-af82-6dcbebeb8498'
'x-envoy-decorator-operation', 'echo.echo.svc.cluster.local:80/*'
'x-envoy-peer-metadata-id', 'sidecar~10.4.2.55~client-f4cd469d6-wnsrx.curl~curl.svc.cluster.local'
'x-envoy-peer-metadata', 'ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwqIAQoGTEFCRUxTEn4qfAoPCgNhcHASCBoGY2xpZW50CisKH3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLW5hbWUSCBoGY2xpZW50CisKI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEgQaAnYxCg8KB3ZlcnNpb24SBBoCdjEKIAoETkFNRRIYGhZjbGllbnQtZjRjZDQ2OWQ2LXduc3J4ChMKCU5BTUVTUEFDRRIGGgRjdXJsCkcKBU9XTkVSEj4aPGt1YmVybmV0ZXM6Ly9hcGlzL2FwcHMvdjEvbmFtZXNwYWNlcy9jdXJsL2RlcGxveW1lbnRzL2NsaWVudAoZCg1XT1JLTE9BRF9OQU1FEggaBmNsaWVudA=='
'x-envoy-attempt-count', '1'
	thread=28
2025-04-29T17:44:56.976066Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:265	[Tags: "ConnectionId":"181"] using existing fully connected connection	thread=28
2025-04-29T17:44:56.976071Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:182	[Tags: "ConnectionId":"181"] creating stream	thread=28
2025-04-29T17:44:56.976084Z	debug	envoy router external/envoy/source/common/router/upstream_request.cc:593	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] pool ready	thread=28
2025-04-29T17:44:56.976117Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:142	[Tags: "ConnectionId":"181"] encode complete	thread=28
2025-04-29T17:44:56.977190Z	debug	envoy router external/envoy/source/common/router/router.cc:1559	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] upstream headers complete: end_stream=false	thread=28
2025-04-29T17:44:56.977274Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1878	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] encoding headers via codec (end_stream=false):
':status', '200'
'x-app-name', 'http-echo'
'x-app-version', '1.0.0'
'date', 'Tue, 29 Apr 2025 17:44:56 GMT'
'content-length', '9'
'content-type', 'text/plain; charset=utf-8'
'x-envoy-upstream-service-time', '1'
'server', 'envoy'
	thread=28
2025-04-29T17:44:56.977301Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:129	[Tags: "ConnectionId":"181"] response complete	thread=28
2025-04-29T17:44:56.977316Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1993	[Tags: "ConnectionId":"192","StreamId":"12612765843006107830"] Codec completed encoding stream.	thread=28
2025-04-29T17:44:56.977361Z	debug	envoy pool external/envoy/source/common/http/http1/conn_pool.cc:53	[Tags: "ConnectionId":"181"] response complete	thread=28
2025-04-29T17:44:56.977368Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:215	[Tags: "ConnectionId":"181"] destroying stream: 0 remaining	thread=28
2025-04-29T17:44:56.977832Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:714	[Tags: "ConnectionId":"192"] remote close	thread=28
2025-04-29T17:44:56.977856Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:276	[Tags: "ConnectionId":"192"] closing socket: 0	thread=28
2025-04-29T17:44:56.977944Z	debug	envoy conn_handler external/envoy/source/common/listener_manager/active_stream_listener_base.cc:136	[Tags: "ConnectionId":"192"] adding to cleanup list	thread=28
```

The key line: `cluster 'outbound|80||echo.echo.svc.cluster.local' match for URL '/'`. Even on an IP-based request, Istio matches it to the known outbound service and handles mTLS correctly.

Now compare that to what happens when we hit `global-echo`:

```
2025-04-29T18:08:46.944432Z	debug	envoy filter external/envoy/source/extensions/filters/listener/original_dst/original_dst.cc:69	original_dst: set destination to 240.240.0.1:80	thread=29
2025-04-29T18:08:46.944666Z	debug	envoy filter external/envoy/source/extensions/filters/listener/http_inspector/http_inspector.cc:139	http inspector: set application protocol to http/1.1	thread=29
2025-04-29T18:08:46.944853Z	debug	envoy conn_handler external/envoy/source/common/listener_manager/active_tcp_listener.cc:160	[Tags: "ConnectionId":"446"] new connection from 10.4.2.55:35226	thread=29
2025-04-29T18:08:46.944900Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:393	[Tags: "ConnectionId":"446"] new stream	thread=29
2025-04-29T18:08:46.944966Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1183	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] request headers complete (end_stream=true):
':authority', 'global-echo'
':path', '/'
':method', 'GET'
'user-agent', 'curl/8.7.1'
'accept', '*/*'
	thread=29
2025-04-29T18:08:46.944980Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1166	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] request end stream timestamp recorded	thread=29
2025-04-29T18:08:46.945014Z	debug	envoy connection external/envoy/source/common/network/connection_impl.h:98	[Tags: "ConnectionId":"446"] current connecting state: false	thread=29
2025-04-29T18:08:46.945174Z	debug	envoy filter source/extensions/filters/http/alpn/alpn_filter.cc:92	override with 3 ALPNs	thread=29
2025-04-29T18:08:46.945206Z	debug	envoy router external/envoy/source/common/router/router.cc:527	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] cluster 'outbound|80||global-echo' match for URL '/'	thread=29
2025-04-29T18:08:46.945308Z	debug	envoy router external/envoy/source/common/router/router.cc:756	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] router decoding headers:
':authority', 'global-echo'
':path', '/'
':method', 'GET'
':scheme', 'http'
'user-agent', 'curl/8.7.1'
'accept', '*/*'
'x-forwarded-proto', 'http'
'x-request-id', 'c7b51081-47e1-491b-ba1e-a87bd4608220'
'x-envoy-decorator-operation', 'global-echo:80/*'
'x-envoy-peer-metadata-id', 'sidecar~10.4.2.55~client-f4cd469d6-wnsrx.curl~curl.svc.cluster.local'
'x-envoy-peer-metadata', 'ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwqIAQoGTEFCRUxTEn4qfAoPCgNhcHASCBoGY2xpZW50CisKH3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLW5hbWUSCBoGY2xpZW50CisKI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEgQaAnYxCg8KB3ZlcnNpb24SBBoCdjEKIAoETkFNRRIYGhZjbGllbnQtZjRjZDQ2OWQ2LXduc3J4ChMKCU5BTUVTUEFDRRIGGgRjdXJsCkcKBU9XTkVSEj4aPGt1YmVybmV0ZXM6Ly9hcGlzL2FwcHMvdjEvbmFtZXNwYWNlcy9jdXJsL2RlcGxveW1lbnRzL2NsaWVudAoZCg1XT1JLTE9BRF9OQU1FEggaBmNsaWVudA=='
'x-envoy-attempt-count', '1'
	thread=29
2025-04-29T18:08:46.945334Z	debug	envoy pool external/envoy/source/common/http/conn_pool_base.cc:78	queueing stream due to no available connections (ready=0 busy=0 connecting=0)	thread=29
2025-04-29T18:08:46.945342Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:291	trying to create new connection	thread=29
2025-04-29T18:08:46.945346Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:145	creating a new connection (connecting=0)	thread=29
2025-04-29T18:08:46.945472Z	debug	envoy connection external/envoy/source/common/network/connection_impl.h:98	[Tags: "ConnectionId":"447"] current connecting state: true	thread=29
2025-04-29T18:08:46.945480Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:57	[Tags: "ConnectionId":"447"] connecting	thread=29
2025-04-29T18:08:46.945488Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1017	[Tags: "ConnectionId":"447"] connecting to 10.4.2.45:8080	thread=29
2025-04-29T18:08:46.945663Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1036	[Tags: "ConnectionId":"447"] connection in progress	thread=29
2025-04-29T18:08:46.945707Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:746	[Tags: "ConnectionId":"447"] connected	thread=29
2025-04-29T18:08:46.947216Z	debug	envoy connection external/envoy/source/common/tls/cert_validator/default_validator.cc:246	verify cert failed: SAN matcher	thread=29
2025-04-29T18:08:46.947284Z	debug	envoy connection external/envoy/source/common/tls/ssl_socket.cc:246	[Tags: "ConnectionId":"447"] remote address:10.4.2.45:8080,TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.947297Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:276	[Tags: "ConnectionId":"447"] closing socket: 0	thread=29
2025-04-29T18:08:46.947340Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:107	[Tags: "ConnectionId":"447"] disconnect. resetting 0 pending requests	thread=29
2025-04-29T18:08:46.947378Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:495	[Tags: "ConnectionId":"447"] client disconnected, failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.947403Z	debug	envoy router external/envoy/source/common/router/router.cc:1384	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] upstream reset: reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.947452Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:463	invoking 1 idle callback(s) - is_draining_for_deletion_=false	thread=29
2025-04-29T18:08:46.962109Z	debug	envoy router external/envoy/source/common/router/router.cc:2013	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] performing retry	thread=29
2025-04-29T18:08:46.962200Z	debug	envoy pool external/envoy/source/common/http/conn_pool_base.cc:78	queueing stream due to no available connections (ready=0 busy=0 connecting=0)	thread=29
2025-04-29T18:08:46.962208Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:291	trying to create new connection	thread=29
2025-04-29T18:08:46.962210Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:145	creating a new connection (connecting=0)	thread=29
2025-04-29T18:08:46.962340Z	debug	envoy connection external/envoy/source/common/network/connection_impl.h:98	[Tags: "ConnectionId":"448"] current connecting state: true	thread=29
2025-04-29T18:08:46.962504Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:57	[Tags: "ConnectionId":"448"] connecting	thread=29
2025-04-29T18:08:46.962520Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1017	[Tags: "ConnectionId":"448"] connecting to 10.4.2.45:8080	thread=29
2025-04-29T18:08:46.962810Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1036	[Tags: "ConnectionId":"448"] connection in progress	thread=29
2025-04-29T18:08:46.962854Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:746	[Tags: "ConnectionId":"448"] connected	thread=29
2025-04-29T18:08:46.964802Z	debug	envoy connection external/envoy/source/common/tls/cert_validator/default_validator.cc:246	verify cert failed: SAN matcher	thread=29
2025-04-29T18:08:46.964857Z	debug	envoy connection external/envoy/source/common/tls/ssl_socket.cc:246	[Tags: "ConnectionId":"448"] remote address:10.4.2.45:8080,TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.964861Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:276	[Tags: "ConnectionId":"448"] closing socket: 0	thread=29
2025-04-29T18:08:46.965002Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:107	[Tags: "ConnectionId":"448"] disconnect. resetting 0 pending requests	thread=29
2025-04-29T18:08:46.965017Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:495	[Tags: "ConnectionId":"448"] client disconnected, failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.965098Z	debug	envoy router external/envoy/source/common/router/router.cc:1384	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] upstream reset: reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:46.965141Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:463	invoking 1 idle callback(s) - is_draining_for_deletion_=false	thread=29
2025-04-29T18:08:47.013428Z	debug	envoy router external/envoy/source/common/router/router.cc:2013	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] performing retry	thread=29
2025-04-29T18:08:47.013521Z	debug	envoy pool external/envoy/source/common/http/conn_pool_base.cc:78	queueing stream due to no available connections (ready=0 busy=0 connecting=0)	thread=29
2025-04-29T18:08:47.013525Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:291	trying to create new connection	thread=29
2025-04-29T18:08:47.013547Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:145	creating a new connection (connecting=0)	thread=29
2025-04-29T18:08:47.013729Z	debug	envoy connection external/envoy/source/common/network/connection_impl.h:98	[Tags: "ConnectionId":"449"] current connecting state: true	thread=29
2025-04-29T18:08:47.013755Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:57	[Tags: "ConnectionId":"449"] connecting	thread=29
2025-04-29T18:08:47.013761Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1017	[Tags: "ConnectionId":"449"] connecting to 10.4.2.45:8080	thread=29
2025-04-29T18:08:47.014191Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:1036	[Tags: "ConnectionId":"449"] connection in progress	thread=29
2025-04-29T18:08:47.014216Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:746	[Tags: "ConnectionId":"449"] connected	thread=29
2025-04-29T18:08:47.015911Z	debug	envoy connection external/envoy/source/common/tls/cert_validator/default_validator.cc:246	verify cert failed: SAN matcher	thread=29
2025-04-29T18:08:47.016058Z	debug	envoy connection external/envoy/source/common/tls/ssl_socket.cc:246	[Tags: "ConnectionId":"449"] remote address:10.4.2.45:8080,TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:47.016062Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:276	[Tags: "ConnectionId":"449"] closing socket: 0	thread=29
2025-04-29T18:08:47.016113Z	debug	envoy client external/envoy/source/common/http/codec_client.cc:107	[Tags: "ConnectionId":"449"] disconnect. resetting 0 pending requests	thread=29
2025-04-29T18:08:47.016138Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:495	[Tags: "ConnectionId":"449"] client disconnected, failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:47.016155Z	debug	envoy router external/envoy/source/common/router/router.cc:1384	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] upstream reset: reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end	thread=29
2025-04-29T18:08:47.016271Z	debug	envoy http external/envoy/source/common/http/filter_manager.cc:1084	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] Sending local reply with details upstream_reset_before_response_started{remote_connection_failure|TLS_error:|268435581:SSL_routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end}	thread=29
2025-04-29T18:08:47.016338Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1878	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] encoding headers via codec (end_stream=false):
':status', '503'
'content-length', '239'
'content-type', 'text/plain'
'date', 'Tue, 29 Apr 2025 18:08:46 GMT'
'server', 'envoy'
	thread=29
2025-04-29T18:08:47.016377Z	debug	envoy http external/envoy/source/common/http/conn_manager_impl.cc:1993	[Tags: "ConnectionId":"446","StreamId":"5689876678243589196"] Codec completed encoding stream.	thread=29
2025-04-29T18:08:47.016499Z	debug	envoy pool external/envoy/source/common/conn_pool/conn_pool_base.cc:463	invoking 1 idle callback(s) - is_draining_for_deletion_=false	thread=29
2025-04-29T18:08:47.017236Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:714	[Tags: "ConnectionId":"446"] remote close	thread=29
2025-04-29T18:08:47.017259Z	debug	envoy connection external/envoy/source/common/network/connection_impl.cc:276	[Tags: "ConnectionId":"446"] closing socket: 0	thread=29
2025-04-29T18:08:47.017318Z	debug	envoy conn_handler external/envoy/source/common/listener_manager/active_stream_listener_base.cc:136	[Tags: "ConnectionId":"446"] adding to cleanup list	thread=29
```

The request routes through `outbound|80||global-echo` -- that's our ServiceEntry cluster. But look at this line:

```
verify cert failed: SAN matcher
```

That's the smoking gun. The SAN (Subject Alternative Name) isn't matching. Quick refresher: a SAN is an extension in X.509 certificates that specifies which identities a certificate is valid for. In Istio's world, this means the SPIFFE ID tied to the workload's service account. Istio uses this during the mTLS handshake to verify "am I actually talking to who I think I'm talking to?"

## The root cause: mismatched SANs in the Envoy cluster config

Let's compare the Envoy cluster configurations between the working and broken cases. You can pull these with:

```
istioctl pc cluster -n curl curl-f4cd469d6-wnsrx --fqdn echo.echo.svc.cluster.local -o json
```

Here's the critical diff:

```diff
                  "defaultValidationContext": {
                    "matchSubjectAltNames": [
                      {
-                       "exact": "spiffe://cluster.local/ns/curl/sa/curl"
                      }
                    ]
                  },
---
                  "defaultValidationContext": {
                    "matchSubjectAltNames": [
                      {
+                       "exact": "spiffe://cluster.local/ns/echo/sa/default"
                      }
                    ]
                  },
```

There it is. In the working configuration (the regular Kubernetes service), Istio expects the *destination's* service account identity (`ns/echo/sa/default`). In our broken ServiceEntry configuration, it's expecting the *source's* identity (`ns/curl/sa/curl`). That's backwards -- the SAN should always match the destination.

## The fix

The ServiceEntry has a `subjectAltNames` field specifically for this. We need to tell Istio what SPIFFE identity to expect when connecting to backends of this service:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: global-curl-global-echo
  namespace: curl
spec:
  hosts:
    - global-echo
  location: MESH_INTERNAL
  ports:
    - name: http
      number: 80
      protocol: HTTP
      targetPort: 8080
  resolution: STATIC
  subjectAltNames:
    - spiffe://cluster.local/ns/echo/sa/default # <----- This is the key
  workloadSelector:
    labels:
      global-service: global-echo
```

Apply that, and:

```bash
$ curl global-echo
cluster1
```

It works. We now have a custom hostname routing directly between pod IPs across clusters, with full mTLS encryption verified by SPIFFE identity.

## TL;DR

Istio's mTLS "just works" when you route through Kubernetes Services -- but when you need to reach pods by IP (common in multi-cluster flat networks), you're on your own to provide the identity information that Istio normally gets for free from the Service object.

If you're using ServiceEntry + WorkloadEntry to route traffic to pod IPs and strict mTLS is breaking things, you need two things:

1. **Add `serviceAccount` to your WorkloadEntries** -- this tells Istio the destination has a sidecar and should use mTLS (without it, Istio sends plaintext)
2. **Add the correct `subjectAltNames` to your ServiceEntry** -- this must be the SPIFFE ID of the *destination* workload's service account, not the source (without it, certificate verification fails)

These two fields are what bridge the gap between "addressing a pod by IP" and "Istio knowing who that pod is."

### Related Issues

* https://github.com/istio/istio/issues/37431
* https://discuss.istio.io/t/503-between-pod-to-pod-communication-1-5-1/6121
* https://stackoverflow.com/questions/62881298/what-is-pod-to-pod-encryption-in-kubernetes-and-how-to-implement-pod-to-pod-enc
