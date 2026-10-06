#!/usr/bin/env bash
# Create a Kairos worker VM in a Cozystack tenant and join it to the tenant's
# Kamaji control plane with plain kubelet TLS bootstrap: no kubeadm, no Cluster
# API bootstrap provider.
#
#   MGMT_CONTEXT       kubectl context of the management cluster
#   TENANT_KUBECONFIG  admin kubeconfig of the tenant Kubernetes cluster
#   TENANT_NAMESPACE   namespace of the TenantControlPlane (default tenant-root)
#   TCP_NAME           TenantControlPlane name
#   DISK_IMAGE         registry reference of the worker raw disk, see README.md
#   STORAGE_CLASS      storage class for the VM disk (default replicated)
set -euo pipefail
: "${MGMT_CONTEXT:?}" "${TENANT_KUBECONFIG:?}" "${TCP_NAME:?}" "${DISK_IMAGE:?}"
ns=${TENANT_NAMESPACE:-tenant-root}
sc=${STORAGE_CLASS:-replicated}
name=${1:-kairos-worker-0}
out=${OUT:-./out}
mkdir -p "$out"
mk() { kubectl --context "$MGMT_CONTEXT" "$@"; }
tk() { KUBECONFIG=$TENANT_KUBECONFIG kubectl "$@"; }

api=$(mk --namespace "$ns" get tenantcontrolplane "$TCP_NAME" --output jsonpath='{.status.controlPlaneEndpoint}')
ca=$(tk config view --raw --output jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)
kubelet_cfg=$(tk --namespace kube-system get configmap kubelet-config --output jsonpath='{.data.kubelet}')

# Kamaji's kubeadm-style RBAC auto-approves CSRs from this group.
tid=$(openssl rand -hex 3); tsec=$(openssl rand -hex 8)
expires=$(date -u -v+1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
tk --namespace kube-system create secret generic "bootstrap-token-${tid}" --type bootstrap.kubernetes.io/token \
  --from-literal=token-id="$tid" --from-literal=token-secret="$tsec" \
  --from-literal=usage-bootstrap-authentication=true --from-literal=usage-bootstrap-signing=true \
  --from-literal=auth-extra-groups=system:bootstrappers:kubeadm:default-node-token \
  --from-literal=expiration="$expires" >/dev/null

indent() { sed 's/^/            /'; }
umask 077
{
cat <<EOF
#cloud-config
hostname: ${name}
stages:
  boot:
    # KubeVirt's DHCP hands out the management CoreDNS but no search domains,
    # so "<svc>.<ns>.svc" names do not resolve. Explicit modes: sudo on Kairos
    # runs with umask 077, which makes the drop-in unreadable to resolved.
    - name: management cluster DNS search domains
      directories:
        - path: /etc/systemd/resolved.conf.d
          permissions: 0755
      files:
        - path: /etc/systemd/resolved.conf.d/cozystack.conf
          permissions: 0644
          content: |
            [Resolve]
            Domains=svc.cozy.local cozy.local svc.cluster.local cluster.local
      commands:
        - systemctl restart systemd-resolved
    # Recovery boots must not register a Node.
    - name: kubelet join material (installed system only)
      if: '[ "\$(kairos-agent state get boot)" = "active_boot" ]'
      files:
        - path: /etc/kubernetes/pki/ca.crt
          permissions: 0644
          content: |
$(printf '%s\n' "$ca" | indent)
        - path: /etc/kubernetes/bootstrap-kubelet.conf
          permissions: 0600
          content: |
            apiVersion: v1
            kind: Config
            clusters:
              - name: tenant
                cluster:
                  server: https://${api}
                  certificate-authority: /etc/kubernetes/pki/ca.crt
            users:
              - name: kubelet-bootstrap
                user:
                  token: ${tid}.${tsec}
            contexts:
              - name: bootstrap
                context:
                  cluster: tenant
                  user: kubelet-bootstrap
            current-context: bootstrap
        - path: /var/lib/kubelet/config.yaml
          permissions: 0644
          content: |
$(printf '%s\n' "$kubelet_cfg" | indent)
        - path: /etc/kubernetes/kubelet.env
          permissions: 0644
          content: |
            NODE_NAME=${name}
      commands:
        - systemctl restart kubelet
EOF
} > "$out/${name}.userdata"

mk --namespace "$ns" delete secret "${name}-userdata" --ignore-not-found >/dev/null
mk --namespace "$ns" create secret generic "${name}-userdata" --from-file=userdata="$out/${name}.userdata" >/dev/null

mk apply --filename - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: ${name}-disk
      spec:
        source:
          registry:
            url: docker://${DISK_IMAGE}
        storage:
          storageClassName: ${sc}
          resources:
            requests:
              storage: 30Gi
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
            - name: system
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: system
          dataVolume:
            name: ${name}-disk
        - name: cloudinit
          cloudInitNoCloud:
            secretRef:
              name: ${name}-userdata
EOF
