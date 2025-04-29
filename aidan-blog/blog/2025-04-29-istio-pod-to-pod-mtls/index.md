---
slug: istio-pod-to-pod-mtls
title: Enabling pod to pod mTLS in Istio
authors: aidancarson
tags: [Istio, ServiceEntry, pod, mTLS, strict, authentication]
---

Imagine a situation where you have multiple different clusters, each running
an Istio service mesh and which are federated together to talk to each other.
Now also imagine that these clusters are networked together such that each
pod IP is uniquely addressable and able to be communicated with from any other
cluster.

I faced a situation like this, where I needed to group endpoints into logical
hostnames that represented services backed by those endpoints. Because endpoints
could live anywhere, in any cluster, I landed on using a ServiceEntry to register
the hostname and WorkloadEntries to represent the endpoints service that hostname.
The configuration looked something like this:

ServiceEntry:
```yaml

```
WorkloadEntry:
```

```

```yaml
```

