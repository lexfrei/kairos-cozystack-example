# kairos-cozystack-example

Kairos images for [Cozystack](https://cozystack.io), built on [Hadron](https://github.com/kairos-io/hadron). This is an experiment, not a supported install path.

- `host/` is a management cluster node: k3s, DRBD and ZFS modules, iSCSI, multipath, and the kernel modules and sysctl settings Cozystack needs. It covers the node preparation that [ansible-cozystack](https://github.com/cozystack/ansible-cozystack) does on Ubuntu.
- `worker/` is a tenant Kubernetes worker that runs as a KubeVirt VM and joins a Kamaji control plane. It carries kubelet, kubeadm and containerd, and no k3s.

## Build

The host image needs the ZFS layer from [kairos-io/hadron-layers#82](https://github.com/kairos-io/hadron-layers/pull/82). Until it is merged and published, build the layer from the PR branch first:

```bash
docker buildx build --load --tag local/hadron-zfs:2.4.4 \
  "https://github.com/lexfrei/hadron-layers.git#feat/zfs-layer:zfs"
docker buildx build --load --tag cozystack-host:0.1.0 \
  --build-arg ZFS_LAYER=local/hadron-zfs:2.4.4 --file host/Containerfile host
```

The worker image builds on its own:

```bash
docker buildx build --load --tag cozystack-worker:0.1.0 --file worker/Containerfile worker
```

Both Containerfiles have a `test` target with static checks: modules match the kernel, units are enabled, the worker's kubeadm matches its kubelet and k3s is absent.

To get a raw EFI disk, run AuroraBoot with `raw-disk.yaml` after putting your SSH key in it. A raw disk boots into recovery, and that file makes the first boot reset into the installed system. The image name needs a path, `docker://name:tag` without one fails to parse.

```bash
docker run --privileged --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/out":/aurora -v "$PWD/raw-disk.yaml":/config.yaml:ro \
  quay.io/kairos/auroraboot:v0.27.1 \
  --set disable_http_server=true --set disable_netboot=true --set disk.efi=true \
  --set container_image=docker://local/cozystack-host:0.1.0 --set state_dir=/aurora \
  --cloud-config /config.yaml
```

## Host

Write `host/k3s-server.yaml` with your values to `/oem/90-k3s.yaml` on each node and reboot. Then install Cozystack as for any k3s cluster.

Pools must use `mountpoint=none`, because the root is read-only.

Kernel 7.2 in Hadron v0.5.3 needs Cilium 1.18.14, 1.19.8, 1.20.2 or newer ([cilium/cilium#48016](https://github.com/cilium/cilium/issues/48016)). Older Cilium agents exit on start.

## Worker

`worker/join-worker.sh` creates a bootstrap token in the tenant cluster, renders NoCloud user-data with the CA, the bootstrap kubeconfig and the tenant's `kubelet-config`, and creates the VM. The join stage runs only on the installed system, never in recovery. Kamaji approves the kubelet CSR by itself.

The image also carries kubeadm, built from the same Kubernetes tag as kubelet, for the `kubeadm join` path of [kairos-io/cluster-api-provider-kairos#141](https://github.com/kairos-io/cluster-api-provider-kairos/pull/141). That path does not work yet: `kubelet.service` is set up for `join-worker.sh` only.

The image ships an empty `/etc/systemd/resolved.conf.d` with mode 0755. Without it, a cloud-config file placed there would make yip create the directory from the file's mode plus owner execute (0744 for a 0644 file), and systemd-resolved could not read the drop-in.

The worker raw disk goes to the VM as a container disk:

```bash
printf 'FROM scratch\nADD --chown=107:107 disk.qcow2 /disk/\n' > out/Containerfile
docker buildx build --push --tag "$DISK_IMAGE" --file out/Containerfile out
```

Cluster API normally sets the following, and here it is manual:

```bash
kubectl patch node "$NODE" --type merge --patch "{\"spec\":{\"providerID\":\"kubevirt://$NODE\"}}"
kubectl annotate node "$NODE" "cluster.x-k8s.io/cluster-namespace=$TENANT_NAMESPACE"
```

Without them kubevirt-csi-node exits. The `kubelet-config` ConfigMap from Kamaji also has no `clusterDNS`, so cluster DNS for pods on this node needs it added.

## How it was tested

- arm64, three Hadron v0.5.3 nodes on OCI Ampere with Cozystack v1.7.0-alpha.3. A three-replica DRBD volume on ZFS zvols survived a reboot of a node with an idle replica and of the node using the volume. The pool came back, all replicas returned to UpToDate, and the data checksum matched.
- amd64, the host image boots on an OCI E5 VM, all modules load, and a pool with a zvol can be created.
- amd64, a worker VM on a Cozystack cluster of OCI E5 nodes joined a Kamaji control plane with Kubernetes v1.35.6, and the Node went Ready.

Those runs built ZFS inline, from an earlier revision of the layer that shipped its own libtirpc. The host image here uses the layer from the PR, and its `test` target passes on arm64.

Cozystack issues found on the way: [#4772](https://github.com/cozystack/cozystack/issues/4772), [#4783](https://github.com/cozystack/cozystack/issues/4783).
