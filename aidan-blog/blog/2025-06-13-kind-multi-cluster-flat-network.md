---
slug: kind-multi-cluster-flat-network
title: Kind multi cluster flat network
authors: aidancarson
tags: [Kind, Kubernetes, Networking, Pod, Linux]
# Display h2 to h5 headings
toc_min_heading_level: 2
toc_max_heading_level: 5
---

# Context

I was trying to set up a multi-cluster kind environment, with a flat network
for communication between clusters. This means that I wanted to be able to have
the pods in one cluster communicate with the pods in another cluster.
This seemed like a hard problem to solve, since the pod IPs aren't communicated
outside the context of the docker container. This article will go over
the different options I considered, as well as what ended up being a straightforward solution
to the problem.

If you're okay with the configuration and overhead, I would use [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/)
to set up a flat network across clusters. This allows not only pod to pod communication,
but also allows pods to address each other by service name by enabling
[Global Service Affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/#enabling-global-service-affinity).

<!-- truncate -->

# Native Routing

If you don't or can't use Cilium there is also a way to connect clusters together using native routing.
It allows you to set up a flat network across clusters, but it does
not allow you to use the kube-dns service to resolve pod IPs across clusters.

## Setup

Here are the steps that you can set up flat networking with native routing using kind:

1. First we need to create the kind clusters. The important part here is to ensure that the pod and service subnets
   do not overlap with each other. Create two kind cluster configs:

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

2. Create the clusters using the configs:
   ```bash
    kind create cluster --config cluster1.yaml --name cluster1
    kind create cluster --config cluster2.yaml --name cluster2
   ``` 

3. Create curl and echo deployments to test connectivity in both clusters:
   ```bash
    kubectl --context kind-cluster1 create deployment curl --image=curlimages/curl
    kubectl --context kind-cluster1 create deployment echo --image=hashicorp/http-echo -- /bin/http-echo -text "\"Hello from cluster1\""
    
    kubectl --context kind-cluster2 create deployment curl --image=curlimages/curl
    kubectl --context kind-cluster2 create deployment echo --image=hashicorp/http-echo -- /bin/http-echo -text "\"Hello from cluster2\""
   ```

## How to configure Native Routing

The trick for configuring native routing is to ensure that the IP address range
of the pods for the other cluster are reachable from the nodes of each cluster.

1. To do this, we first get the IP address of the target cluster:

   ```bash 
   $ docker inspect cluster2-worker -f "{{.NetworkSettings.Networks.kind.IPAddress}}"
   172.18.0.3
   ```

2. Then in the cluster we want to enable connectivity in, we add a route to the pod network of the target cluster.
   For example, in `cluster1`, we want to add a route `cluster2`'s pod network.

   ```bash
   # note 10.2.0.0/16 from cluster2.yaml's pod subnet
   # We set the next hop to the IP address of the control plane node of cluster2
   $ docker exec cluster1-worker ip route add 10.2.0.0/16 via 172.18.0.3
   ```   
   
   And we can do the same for the service subnet:

   ```bash
   $ docker exec cluster1-worker ip route add 10.3.0.0/16 via 172.18.0.3
   ```

3. Now if we get the ip address of the echo pod in cluster 2:
   ```bash
   $ kubectl get pod -o wide --context kind-cluster2
   NAME                   READY   STATUS    RESTARTS   AGE     IP           NODE              NOMINATED NODE   READINESS GATES
   echo-9b959696d-547qm   1/1     Running   0          4m48s   10.6.1.108   cluster2-worker   <none>           <none>
   ```
   
   We can see that the pod IP is `10.6.1.108`

4. And if we try to curl that pod IP from the curl pod in cluster 1:
   ```bash
   $ kubectl exec -it curl-6b7f4c5d6c-8j5qk --context kind-cluster1 -- curl
   ```

[//]: # (TODO:)

