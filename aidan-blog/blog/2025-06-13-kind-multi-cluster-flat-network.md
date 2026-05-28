---
slug: kind-multi-cluster-flat-network
title: Networking Multiple Kind Kubernetes Clusters Together Using Native Routing
authors: aidancarson
tags: [Kind, Kubernetes, Networking, Pod, Linux]
# Display h2 to h5 headings
toc_min_heading_level: 2
toc_max_heading_level: 5
---

# Setting up a flat network across Kind clusters

If you've ever needed to test multi-cluster Kubernetes features locally -- things like service mesh federation, cross-cluster service discovery, or multi-cluster networking -- you've probably hit the same wall I did: pods in one Kind cluster can't talk to pods in another. Their IPs are trapped inside their respective Docker containers with no route between them.

This post covers how to solve that by creating a flat network where any pod in any cluster can reach any other pod by IP.

## When would you need this?

You'd reach for this setup when:

- **Testing multi-cluster service meshes** (Istio, Linkerd, Cilium) locally before deploying to real infrastructure
- **Developing cross-cluster controllers** that need direct pod-to-pod communication
- **Reproducing multi-cluster networking bugs** in a lightweight local environment
- **Validating flat-network assumptions** before committing to a CNI or network topology in production

If your use case also needs cross-cluster DNS resolution (pods addressing services by name across clusters), skip ahead to the Cilium recommendation below. If you just need IP-level reachability, the native routing approach will get you there with zero extra dependencies.

<!-- truncate -->

## Option 1: Cilium Service Mesh (the batteries-included approach)

If you're okay with the extra configuration and overhead, [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/) is the most fully-featured option. It gives you not just pod-to-pod communication across clusters, but also allows pods to address each other by service name via [Global Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/#enabling-global-service-affinity).

The tradeoff is that Cilium brings its own CNI, eBPF dataplane, and cluster mesh configuration. For local testing where you just need raw IP connectivity, that can be more than you bargained for.

## Option 2: Native routing (the lightweight approach)

If you don't need (or can't use) Cilium, there's a surprisingly simple way to connect Kind clusters using native Linux routing. The idea is straightforward: since Kind clusters run as Docker containers on the same host, we just need to tell each container how to reach the other cluster's pod network.

The catch: this approach gives you pod IP reachability only. You won't get cross-cluster DNS resolution -- pods can't `curl service-name.namespace` across cluster boundaries. But for many testing scenarios, direct IP connectivity is all you need.

### Prerequisites

The key requirement is that **pod and service subnets must not overlap** between clusters. By default Kind uses the same subnets for every cluster, so we need to configure them explicitly.

### Step 1: Create the Kind clusters with non-overlapping subnets

The first cluster:
```bash
cat << EOF > cluster1.yaml 
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
networking:
   disableDefaultCNI: true
   podSubnet: "10.0.0.0/16"
   serviceSubnet: "10.1.0.0/16"
EOF
```

The second cluster:
```bash
cat << EOF > cluster2.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
networking:
   disableDefaultCNI: true
   podSubnet: "10.2.0.0/16"
   serviceSubnet: "10.3.0.0/16"
EOF
```

Notice the subnets are completely distinct: cluster1 gets `10.0.0.0/16` and `10.1.0.0/16`, cluster2 gets `10.2.0.0/16` and `10.3.0.0/16`. No overlap means no routing ambiguity.

Now create both clusters:
```bash
kind create cluster --config cluster1.yaml --name cluster1
kind create cluster --config cluster2.yaml --name cluster2
``` 

### Step 2: Deploy test workloads

Let's put something in each cluster so we can verify connectivity later:

```bash
kubectl --context kind-cluster1 create deployment curl --image=curlimages/curl
kubectl --context kind-cluster1 create deployment echo --image=hashicorp/http-echo -- /bin/http-echo -text "\"Hello from cluster1\""

kubectl --context kind-cluster2 create deployment curl --image=curlimages/curl
kubectl --context kind-cluster2 create deployment echo --image=hashicorp/http-echo -- /bin/http-echo -text "\"Hello from cluster2\""
```

### Step 3: Add cross-cluster routes

Here's where the magic happens. Since all Kind nodes are Docker containers on the same Docker network, they can already reach each other at the container level. We just need to add routes so that each node knows "to reach the *other* cluster's pod subnet, forward traffic to that cluster's node."

First, find the Docker IP of the target cluster's worker node:

```bash 
$ docker inspect cluster2-worker -f "{{.NetworkSettings.Networks.kind.IPAddress}}"
172.18.0.3
```

Then add a route inside cluster1's worker node pointing cluster2's pod subnet at that IP:

```bash
# 10.2.0.0/16 is cluster2's pod subnet from our config above
# 172.18.0.3 is cluster2-worker's Docker IP
$ docker exec cluster1-worker ip route add 10.2.0.0/16 via 172.18.0.3
```

You can do the same for the service subnet if you need service IP reachability too:

```bash
$ docker exec cluster1-worker ip route add 10.3.0.0/16 via 172.18.0.3
```

And don't forget to do the reverse -- add routes in cluster2 pointing back to cluster1's subnets:

```bash
$ docker inspect cluster1-worker -f "{{.NetworkSettings.Networks.kind.IPAddress}}"
# Use that IP as the gateway
$ docker exec cluster2-worker ip route add 10.0.0.0/16 via <cluster1-worker-ip>
$ docker exec cluster2-worker ip route add 10.1.0.0/16 via <cluster1-worker-ip>
```

### Step 4: Verify cross-cluster connectivity

Now grab the pod IP of the echo deployment in cluster2:

```bash
$ kubectl get pod -o wide --context kind-cluster2
NAME                   READY   STATUS    RESTARTS   AGE     IP           NODE              NOMINATED NODE   READINESS GATES
echo-9b959696d-547qm   1/1     Running   0          4m48s   10.2.1.108   cluster2-worker   <none>           <none>
```

And curl it from the curl pod in cluster1:

```bash
$ kubectl exec -it <curl-pod-name> --context kind-cluster1 -- curl 10.2.1.108:5678
Hello from cluster2
```

That's it -- direct pod-to-pod communication across Kind clusters using nothing but Linux routing.

## Things to keep in mind

- **Routes don't survive restarts.** If you recreate a Kind cluster, you'll need to re-add the routes. Consider scripting this as part of your cluster setup.
- **Multi-node clusters need routes on every node.** If your Kind cluster has multiple worker nodes, you'll need to add routes on each one (or add routes on the control-plane node if traffic flows through it).
- **CNI matters.** We set `disableDefaultCNI: true` in the configs above. You'll need to install a CNI that respects these subnets (like Calico or Cilium in native routing mode). Without a CNI, pods won't get IPs at all.
- **No DNS across clusters.** This approach only gives you IP-level connectivity. If you need service name resolution across clusters, look into Cilium ClusterMesh or a multi-cluster DNS solution.

## Wrapping up

For local multi-cluster testing, you don't always need a full-blown service mesh or cluster federation tool. Sometimes a few `ip route add` commands are all it takes to get pods talking across cluster boundaries. Start here, and layer on complexity (Cilium, Istio, etc.) only when your testing actually requires it.
