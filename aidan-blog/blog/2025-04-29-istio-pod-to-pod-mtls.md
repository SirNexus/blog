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

Imagine a situation where you have multiple different clusters, each running
an Istio service mesh and which are federated together to talk to each other.
Now also imagine that these clusters are networked together such that each
pod IP is uniquely addressable and able to be communicated with from any other
cluster.

## Context

I faced a situation like this, where I needed to group endpoints into logical
hostnames that represented services backed by those endpoints. Because endpoints
could live anywhere, in any cluster, I landed on using a ServiceEntry to register
the hostname and WorkloadEntries to represent the endpoints service that hostname.

But a problem came on enabling PeerAuthentication:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: prod-istio-system # The namespace of our istio installation
spec:
  mtls:
    mode: STRICT
```

Curl stopped working!

```bash
$ curl global-echo
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

Through some debugging, I was able to get it to:
```bash
$ curl global-echo
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, 
transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end
```

But to find the true root cause and solution took some digging.

Let's get into it

<!-- truncate -->

## Setup

The configuration looked something like this:

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

These resources specify a host `global-echo`, and two backend services each of which
live in their own clusters. Behind the scenes, I have these services running simple
echo servers. If you'd like that yaml, here it is:

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

And it works! I can curl both pods in my mesh:

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

## The Problem

So networking is working. Istio is generating the correct Envoy config such that
our global hostname routes to our backing services on each cluster. But what about
security? Just to make sure that Istio is actually performing mTLS between pods,
let's turn on strict mTLS.

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

Let's check that our communication still works:

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

Our connection broke! What gives! I thought Istio was routing our services? Spoiler:
our connection broke because istio was using PERMISSIVE mode and sending our traffic
over plaintext. Now that we are enforcing STRICT mTLS mode, Istio is breaking.
This means that we weren't secure before, sending traffic over plaintext. This is
super interesting. Istio should be handling the upgrading of our communication to
mTLS by default. So what's happening? Let's do some testing.

## Finding the Solution

So let's look at the local endpoint. Curling from cluster1, we have a local echo
pod IP of `10.4.2.45`. Let's curl that:

```bash
$ curl 10.4.2.45
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

Hm, so that's broken. That makes sense, since the service entry is just resolving
DNS requests to the WorkloadEntry specifying `curl 10.4.2.45`.

But now let's try the echo service itself:

```bash
$ curl echo.echo
cluster1
```

That works! How strange! So istio is *capable* of routing our traffic over mTLS,
it just isn't when connecting to the **pod IP** rather than service.

Okay, so what about service IP? Let's get the ip of the associated echo service:

```bash
$ kubectl get svc -n echo
NAME            TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
echo            ClusterIP   10.5.113.88   <none>        80/TCP    48m
```

And now let's curl that:

```bash
$ curl 10.5.113.88
cluster1
```

That also works! So from this we can conclude that Istio is routing things correctly
when using the service name or service IP, but not when using the pod IP. Upon further
reflection on the Istio documentation on [WorkloadEntry](https://istio.io/latest/docs/reference/config/networking/workload-entry/),
these lines stand out:

```
...
  # use of the service account indicates that the workload has a
  # sidecar proxy bootstrapped with this service account. Pods with
  # sidecars will automatically communicate with the workload using
  # istio mutual TLS.
  serviceAccount: details-legacy
```

This means that when working with a WorkloadEntry, Istio looks for a serviceAccount
associated with the pod to communicate over mTLS. So let's add that:

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

Now, let's try our global-echo curl:

```bash
$ curl global-echo
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, transport failure reason: TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end
```

Weird. Now we're getting a certificate issue. I suppose this means Istio is *trying*
to communicate with the pod over mTLS, but there's clearly a certificate issue going wrong.
It's time to look at the Istio logs.

On a successful request (`curl 10.5.113.88`), we see Istio logs coming from the client
sidecar:
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

Note particularly the line `cluster 'outbound|80||echo.echo.svc.cluster.local' match for URL '/'	thread=28`.
This gives us some important information. Even on an IP route to the service,
Istio is matching the request to the outbound service it has configured.

Let's compare that to the log when we send a request to the `global-echo` service:

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

As you can see, the request is being handled by the `outbound|80||global-echo` cluster,
and yet the upstream server is still responding with a 503. There is a pertinent
part here that hints at what might be going wrong:

```
2025-04-29T18:08:46.947216Z	debug	envoy connection external/envoy/source/common/tls/cert_validator/default_validator.cc:246	verify cert failed: SAN matcher	thread=29
```

our SAN isn't getting matched. For anyone not super familiar, a
SAN stands for Subject Alternative Name. It is an extension in X.509 certificates (used in TLS/SSL) that allows you to 
specify additional identities (such as DNS names, IP addresses, or URIs) that the certificate should be valid for, 
beyond the primary Common Name (CN). Istio uses this to verify the spiffeID
associated with the serviceAccount used in the mTLS handshake.

Let's debug the cluster configuration next in envoy and see if there's a difference.

(Commands gotten with `istioctl pc cluster -n curl curl-f4cd469d6-wnsrx --fqdn echo.echo.svc.cluster.local -o j
son`)

Diff between cluster configs of not working (`-`) and not working (`+`)
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
(Note the output has been cleaned to show the pertinent, non-trivial parts)

This is the key. Inside of Istio's tls configuration, the configured SAN in
the working configuration is associated with the *destination* service account,
while in the non-working configuration, it is associated with the *source* service account.

According to the Istio documentation, we can edit the SAN inside of our ServiceEntry:
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
    - spiffe://cluster.local/ns/echo/sa/default # <----- Added this
  workloadSelector:
    labels:
      global-service: global-echo
```

And once that's applied, we can test our custom host:

```bash
$ curl global-echo
cluster1
```

It works! So now we have a custom host routing directly between pod IPs.

## Summary

In this post, we learned how to set up a custom host in Istio that routes between
two different clusters. We learned how to set up a ServiceEntry and WorkloadEntry
to route between the two clusters, and how to set up a custom SAN in the ServiceEntry
to allow for mTLS communication between the two clusters. We also learned how to
debug the Istio configuration to find out what was going wrong with our mTLS
configuration, and how to fix it by adding the correct SAN to the ServiceEntry.

### Related Issues

* https://github.com/istio/istio/issues/37431
* https://discuss.istio.io/t/503-between-pod-to-pod-communication-1-5-1/6121
* https://stackoverflow.com/questions/62881298/what-is-pod-to-pod-encryption-in-kubernetes-and-how-to-implement-pod-to-pod-enc
