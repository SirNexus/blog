---
slug: kind-multi-cluster-flat-network
title: Networking Multiple kind Kubernetes Clusters Together Using Native Routing
authors: aidancarson
tags: [Kind, Kubernetes, Networking, Pod, Linux]
# Display h2 to h5 headings
toc_min_heading_level: 2
toc_max_heading_level: 5
---

Recently, I set out to create a multi-cluster kind environment where clusters could communicate over a flat network. 
The goal was simple: pods in one cluster should be able to directly talk to pods in another cluster without requiring tunneling or proxies.

At first glance, this seemed tricky — the pod IPs assigned inside kind clusters exist only within the containerized 
network of each cluster, and Docker isolates these networks by default. However, I eventually found a straightforward 
solution that uses native routing, and I wanted to share my journey and what worked.

## The Challenge
By design, kind runs Kubernetes clusters inside Docker containers. This means:

* Pod IPs are only visible inside the Docker network created for each kind cluster.
* There’s no built-in way for a pod in one cluster to directly communicate with a pod in another cluster using its pod IP.
* Bridging these isolated networks requires either complex overlay solutions or manual routing.

<!-- truncate -->

## Options Considered
1. Use Cilium Service Mesh
   * If you’re okay with the added configuration and overhead, Cilium Service Mesh is a great choice:
   * It can establish a flat network across multiple clusters.
   * With [Global Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/#enabling-global-service-affinity),
     services in different clusters can even resolve each other’s names and load balance between them.


2. Native Routing Using ip route (The solution that worked): manually add routes 
   to each Docker container that runs a kind node.
   * Each node knows how to route pod traffic destined for another cluster’s pod subnet.
   * Traffic flows directly via the Docker bridge network, using the container IP of the appropriate node as the next hop.


For my use case, I wanted a lighter-weight solution that didn’t require
deploying cilium cluster mesh, so I opted for the native routing approach.

## Example Configuration

Here’s an example kind config I used to define pod and service subnets:

```yaml

kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
   - role: control-plane
   - role: worker
     networking:
     disableDefaultCNI: true
     podSubnet: "10.0.0.0/16"
     serviceSubnet: "10.1.0.0/16"
```
To make routing work, I added routes like:

```bash
ip route add 10.0.0.0/16 via <docker-container-ip-of-cluster1-node>
ip route add 10.2.0.0/16 via <docker-container-ip-of-cluster2-node>
```
Each via IP corresponds to a Docker container (the kind node) that knows how to reach its local pod subnet.

## Example Workflow
1. Create two kind clusters with distinct pod subnets:

Cluster A: 10.0.0.0/16

Cluster B: 10.2.0.0/16

2. Retrieve the Docker container IPs for the nodes in each cluster:

```bash
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <container-name>
```
3. On each kind node container, add routes for the other cluster’s pod subnet:

```bash
docker exec <cluster-a-node> ip route add 10.2.0.0/16 via <cluster-b-node-ip>
docker exec <cluster-b-node> ip route add 10.0.0.0/16 via <cluster-a-node-ip>
```

The Result: Pods in Cluster A can now talk to pods in Cluster B by pod IP, and vice versa!

## Final Thoughts
If you’re experimenting with multi-cluster setups in a local or CI environment, 
this native routing method is lightweight and effective. That said, for production-like features (service discovery, identity-aware routing, encryption), service mesh solutions like Cilium offer more power and flexibility.

## A note for Cilium and service networking

If you're using Cilium for your CNI, you'll want to use the `bpf.lbExternalClusterIP`
option in helm. This will expose the cluster IPs to the host network on the nodes,
allowing you to also address the service IPs from your other clusters.

Happy clustering! If you have any questions or suggestions, feel free to reach out.
