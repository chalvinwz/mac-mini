# A three-node Kubernetes cluster on a Mac mini, reachable from your LAN

Builds a real Kubernetes cluster — three nodes, a CNI, a LoadBalancer, TLS ingress.

Everything is a plain manifest applied with `kubectl`. Every
file is in this directory and every command below is complete.

**What you end up with**

| | |
|---|---|
| 3 nodes | 1 control plane, 2 workers, each with a real address on your LAN |
| Calico | Pod networking and enforced NetworkPolicy |
| MetalLB | A LoadBalancer address other machines can actually reach |
| Traefik + Gateway API | TLS-terminating ingress, HTTP redirected to HTTPS |
| cert-manager | A private CA that issues and renews every certificate |
| An in-cluster registry | So nodes pull images without an external service |
| An example application | 12 images, Postgres, Redis, NATS, an autoscaler |

---

## Requirements

- **A Mac mini with Apple Silicon**, macOS Sonoma (14) or newer. Any Mac works; this is written
  around a mini because it is the natural machine to leave running
- **16 GB of RAM or more.** The layout here uses 10 GiB across three VMs
- **8 cores or more.** Six vCPUs are allocated, plus QEMU's own overhead
- **~40 GB free disk.** Thin-provisioned, so it grows rather than being reserved
- **Wired Ethernet strongly preferred.** Many Wi-Fi adapters refuse to carry frames for a second
  MAC address, which breaks bridging in a way that looks like a DHCP fault
- **Six free IP addresses** on your LAN, and the authority to use them
- **Homebrew**, and Apple's Command Line Tools. Both are covered below if you do not have them
- **Docker**, on whichever machine builds the images in part 4 — OrbStack or Docker Desktop, either
  is fine. **No step below installs it.** It does not have to be this Mac: the registry is reachable
  from anywhere on the LAN, so building on a second machine keeps a Rust workspace compile off a
  host already running three QEMU guests. See [README.md](../README.md) for the two-machine split
  we actually use

---

## Values you must change

Everything below uses concrete addresses. **They are almost certainly wrong for your network.**
Work through this table first — it is the only place these values appear as a list, and every
file that contains one is named here.

| Value used here | What it is | Files to change |
|---|---|---|
| `10.218.65.0/24` | Your LAN's subnet | — |
| `10.218.65.1` | Your LAN's gateway | `param.gateway` in all three files in `1-lima/` |
| `103.94.168.168, 8.8.8.8, 1.1.1.1` | Your LAN's DNS servers | `param.dns` in all three files in `1-lima/` |
| `10.218.65.20` | The Lima host itself — the Mac mini, not a cluster node | No file. Set statically in macOS System Settings → Network → Ethernet → Details → TCP/IP |
| `10.218.65.21` | control-plane-01 | `1-lima/control-plane-01.yaml` (`param.nodeIP`), `2-cluster/kubeadm-config.yaml` (`advertiseAddress`, `certSANs`) |
| `10.218.65.22`, `.23` | worker-01, worker-02 | `1-lima/worker-01.yaml`, `1-lima/worker-02.yaml` (`param.nodeIP`), and `2-cluster/join-worker-0*.yaml` (`node-ip`, `apiServerEndpoint`) |
| `10.218.65.27`–`.29` | MetalLB address pool, three addresses | `2-cluster/metallb-pool.yaml` |
| `10.218.65.27` | Traefik's LoadBalancer address | `2-cluster/traefik/02-service.yaml` |
| `planpal.10-218-65-27.traefik.me` | Frontend hostname | `2-cluster/cert-manager-gateway-cert.yaml`, `3-app/60-web.yaml`, `3-app/20-config.yaml` |
| `planpal-api.10-218-65-27.traefik.me` | API hostname | `2-cluster/cert-manager-gateway-cert.yaml`, `3-app/20-config.yaml`, `3-app/4*-*.yaml` |
| `registry.10-218-65-27.traefik.me` | In-cluster registry hostname | `2-cluster/cert-manager-gateway-cert.yaml`, `2-cluster/registry.yaml`, every `image:` in `3-app/` |
| `10.251.0.0/16` | Pod network, internal | `2-cluster/kubeadm-config.yaml`, `2-cluster/calico-installation.yaml` — **must match in both** |
| `10.100.0.0/16` | Service network, internal | `2-cluster/kubeadm-config.yaml` |


### Two constraints you cannot ignore

**The MetalLB pool must be free addresses inside your nodes' own subnet.** Not a range you invent.
MetalLB announces addresses by answering ARP, and a machine only sends an ARP request for an
address it believes is on its own subnet — anything else it hands to its router, which has no
route to it. A pool outside the subnet produces a LoadBalancer that looks configured and is
unreachable from everywhere.

**The pod and service networks must not overlap anything you can route to.** They are invented
addresses that exist only inside the cluster. `10.251.0.0/16` and `10.100.0.0/16` do not clash
with `10.218.65.0/24`, but if your network routes other parts of `10.0.0.0/8`, pick different
ones.

Check each address you intend to claim is idle before claiming it:

```bash
for i in 21 22 23 27 28 29; do printf "  .%s " $i; ping -c1 -W1 10.218.65.$i >/dev/null 2>&1 && echo IN USE || echo free; done
```

All `free`. A static address takes no DHCP lease, so nothing else will warn you about a collision.

### A caution about static addresses on a managed network

Because these nodes take no DHCP lease, the DHCP server does not know their addresses are in use.
If your range sits inside the server's dynamic pool rather than being excluded from it, you can
get an address conflict weeks later. Confirm the range is excluded, not merely yours by
convention.

---

## How to read this

Run every command from **this directory**:

```bash
cd mac-mini
```

All paths are relative to it — `1-lima/worker-01.yaml`, `2-cluster/metallb-pool.yaml`, and so on.

### Three machines are involved. Keep them straight.

| Machine | Role in this document |
|---|---|
| **Mac mini** | The Lima host. Homebrew, `limactl`, this repository, the image builds, and `kubectl` during the build all live here. It sits on the same subnet as the nodes |
| **control-plane-01**, **worker-01**, **worker-02** | The Lima virtual machines. The Kubernetes nodes |
| **MacBook** | Wherever you actually sit. Used to prove the cluster is reachable from *outside* its own subnet, and optionally to run `kubectl` once everything works |

The MacBook matters more than it sounds. The Mac mini can reach the nodes trivially — it hosts them.
Only a separate machine proves the bridged addresses work as real LAN addresses, which is the entire
point of the exercise. If you have no second machine, any phone on the same network will do for the
browser check at the end.

**Every command block below is preceded by where it runs:**

| Label | Meaning |
|---|---|
| **On the Mac mini** | A terminal on the Lima host. This is the default when no label is given |
| **On control-plane-01** / **worker-01** / **worker-02** | A shell *inside* that virtual machine |
| **On your MacBook** | The separate machine, to test reachability from outside |

Most work inside the nodes is driven from the Mac mini with `limactl shell <node> -- <command>`,
which runs one command in that VM and returns. Those blocks are labelled **On the Mac mini**,
because that is where you type them — the command itself executes inside the node.

When you would rather be inside a node, for poking around or reading logs:

```bash
limactl shell control-plane-01
```

That drops you at a prompt in the VM; `exit` comes back. Anything after `-- ` in the labelled
commands is exactly what you would type at that prompt.

Each step ends with a verification and the output you should see. When it does not match, the note
underneath usually names the cause. The Troubleshooting table at the end is indexed by symptom.

### What is in this directory

| Path | Contents |
|---|---|
| `1-lima/control-plane-01.yaml` | VM definition for the control plane, 2 CPU / 4 GiB |
| `1-lima/worker-01.yaml` | VM definition for worker-01 at `.22`, 2 CPU / 3 GiB |
| `1-lima/worker-02.yaml` | VM definition for worker-02 at `.23`, 2 CPU / 3 GiB |
| `1-lima/node-prep.sh` | Runs inside each VM: swap off, kernel modules, sysctls, containerd, kubeadm |
| `2-cluster/kubeadm-config.yaml` | Control plane configuration for `kubeadm init` |
| `2-cluster/join-worker-01.yaml` | Join configuration for worker-01. Two placeholders to fill in |
| `2-cluster/join-worker-02.yaml` | Join configuration for worker-02. Two placeholders to fill in |
| `2-cluster/calico-installation.yaml` | Calico `Installation` and `APIServer` resources |
| `2-cluster/metallb-pool.yaml` | The address pool and its L2 advertisement |
| `2-cluster/cert-manager-ca.yaml` | The private CA: bootstrap issuer, CA certificate, CA issuer |
| `2-cluster/cert-manager-gateway-cert.yaml` | The server certificate the Gateway serves |
| `2-cluster/traefik/` | RBAC, Deployment, Service, GatewayClass and Gateway |
| `2-cluster/registry.yaml` | In-cluster image registry and its route |
| `3-app/` | The example application, ~20 numbered manifests |
| `3-app/make-secrets.sh` | Renders `3-app/05-secrets.yaml` from the app repos' `.env` files |
| `3-app/secrets.example.yaml.tpl` | Reference showing every key the application needs |

### Versions

These are pinned deliberately and are the versions this was built and verified against.

| Component | Version |
|---|---|
| Kubernetes | v1.36.0 |
| Ubuntu | 26.04 |
| Calico | v3.31.0 |
| MetalLB | v0.16.1 |
| Gateway API | v1.5.1 |
| cert-manager | v1.21.1 |
| Traefik | v3.7.10 |
| metrics-server | v0.8.0 |
| local-path-provisioner | v0.0.37 |

---
---

# Part 1 — Prepare the Mac mini

## 0. Install Homebrew, if you do not have it

Skip this if `brew --version` already works.

Then Homebrew itself, using its official installer verbatim:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

https://brew.sh/

---

## 1. Install Lima and QEMU

```bash
brew install lima qemu
```

**QEMU is a separate package and Lima does not depend on it.** Without it, starting a VM fails
with a missing-binary error rather than anything that mentions QEMU.

```bash
limactl --version
```

Needs 2.0.0 or newer. The VM definitions use template inheritance, which is a 2.x feature.

### Why QEMU and not Apple's hypervisor

Lima can run guests under `vz`, which uses Apple's Virtualization.framework and is faster,
especially for disk. This cluster uses `qemu` instead, and the reason is not a preference:

**Bridged networking is only available under QEMU.** It is implemented by `socket_vmnet`, which
QEMU attaches to. The Virtualization.framework equivalent, `VZBridgedNetworkDeviceAttachment`,
requires Apple's `com.apple.vm.networking` entitlement, which is granted by arrangement with
Apple. So `vz` guests are limited to NAT — they get a working address, but on a private range
nothing outside the Mac mini can route to, which defeats the entire point of MetalLB.

---

## 2. Build socket_vmnet from source

**Do not install this from Homebrew.** Lima's documentation is explicit: *"Installation using
Homebrew is not secure and not recommended by the Lima project."*

The reason is concrete. `socket_vmnet` runs as root, and Homebrew's prefix is writable by your
normal user account — so anything able to write there could execute code as root. Lima generates
sudoers rules pinned to a path it expects to be root-owned, and refuses a user-writable one.

```bash
git clone https://github.com/lima-vm/socket_vmnet.git /tmp/socket_vmnet
```

```bash
cd /tmp/socket_vmnet && sudo make PREFIX=/opt/socket_vmnet install.bin
```

```bash
ls -l /opt/socket_vmnet/bin/
```

Two binaries, `socket_vmnet` and `socket_vmnet_client`, both owned by `root`.

```bash
cd -
```

Back to `mac-mini/` for everything that follows.

---

## 3. Grant Lima permission to start the network

`socket_vmnet` needs root to open `vmnet.framework`. Rather than running Lima as root, Lima
generates a narrow sudoers rule permitting exactly the invocations it needs:

```bash
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

Re-run this after upgrading Lima or moving the binary. The rules embed both the path and the
network definitions, so a stale file causes a permission failure when a VM starts.

---

## 4. Confirm the bridged network definition

Lima ships this definition already — check it rather than writing it:

```bash
cat ~/.lima/_config/networks.yaml
```

Two things must be right.

**First, the `bridged` stanza:**

```yaml
  bridged:
    mode: bridged
    interface: en0
```

`interface` here is the **Mac's** interface to bridge onto. Confirm yours has a live link, because
bridging onto an interface with no link produces a guest with no network and no error explaining
why:

```bash
ifconfig en0 | grep -E 'status|inet '
```

Wants `status: active` and an address on your LAN. If the Mac mini is on Wi-Fi that interface is
usually `en1` — and see the Requirements note about Wi-Fi and bridging.

**Second, the `paths` section:**

```bash
sed -n '/^paths:/,/^[a-z]/p' ~/.lima/_config/networks.yaml
```

| Key | Expected | Why |
|---|---|---|
| `socketVMNet` | `/opt/socket_vmnet/bin/socket_vmnet` | Must be root-owned, with no parent directory writable by you |
| `varRun` | `/private/var/run/lima` | Must **not** be writable by you — it holds the daemon's pid file |
| `sudoers` | `/private/etc/sudoers.d/lima` | The same file as `/etc/sudoers.d/lima`; `/etc` is a symlink on macOS |

Note what the shipped comment says: *bridged mode doesn't have a gateway; dhcp is managed by
outside network*. Lima assigns nothing in this mode. That is why the VM definitions configure
static addresses themselves.

---
---

# Part 2 — Create the three virtual machines

## 5. Understand the three definitions

| File | CPU / memory | Used for |
|---|---|---|
| `1-lima/control-plane-01.yaml` | 2 / 4 GiB | control-plane-01 at `10.218.65.21` |
| `1-lima/worker-01.yaml` | 2 / 3 GiB | worker-01 at `10.218.65.22` |
| `1-lima/worker-02.yaml` | 2 / 3 GiB | worker-02 at `10.218.65.23` |

10 GiB total, which is what fits on a 16 GB Mac alongside macOS and three QEMU processes. Four
nodes at these sizes does not fit. `kubeadm` refuses to start with fewer than 2 CPUs, so 2 is a
floor rather than a choice.

Each file does five things. Two of them are the difference between a working cluster and a
mysterious one.

**`vmType: qemu`** — required for bridged networking, as explained in step 1.

**`containerd: system: false` and `user: false`** — Lima installs its own containerd and nerdctl by
default. A `kubeadm` node needs containerd configured for the CRI with the systemd cgroup driver,
and two installations contending for the same socket produces a kubelet failure that never
mentions containerd.

**`networks: - lima: bridged` with `interface: lima0`** — attaches the guest to the bridged
definition from step 4. `lima0` is the name the interface gets **inside the guest**; `en0` in
`networks.yaml` was the name of the **Mac's** interface. Lima reuses the word `interface` for both,
which catches everyone once. Pin it, because the default is `lima` plus the entry's index in the
network list — adding another network ahead of this one would silently rename it to `lima1` and
break the static configuration below.

**A static address, via a netplan drop-in.** This one needs explaining because it looks
roundabout. Lima has no field for a static address, and the cloud-init configuration it generates
hardcodes DHCP on for every network. You cannot edit the file it writes either: Lima deliberately
regenerates the cloud-init instance-id on every start so that network configuration is reprocessed,
which overwrites it. What does work is that cloud-init writes only `/etc/netplan/50-cloud-init.yaml`
and then runs `netplan generate`, which reads every file in `/etc/netplan` — so a higher-numbered
file wins, on every boot, with nothing to re-run. Three details make it correct:

- `dhcp4: false` is **mandatory**. Netplan overwrites scalars but *concatenates* sequences, so
  supplying an address without disabling DHCP leaves a DHCP client racing your static address.
- The file reuses the netdef ID `lima0`. Inventing a second ID for the same interface produces two
  conflicting definitions instead of an override.
- Mode `0600`. Netplan warns on group-read, group-write, other-read *or* other-write, so `0644`
  and `0640` both warn.

### Every node has two interfaces, and that has to be handled

`lima0` carries the node's real address. `eth0` carries `192.168.5.15` — Lima's own management
network, and it is the **same address on every node**.

Kubelet picks its node address from whichever interface holds the default route, and `kubeadm`
autodetects the API server's advertise address the same way. Get either wrong and nodes register
duplicate addresses, which fails in ways that never mention networking.

Both are pinned in the cluster configuration rather than left to autodetection, in
`2-cluster/kubeadm-config.yaml` for the control plane and `2-cluster/join-worker-0*.yaml` for the
workers:

```yaml
nodeRegistration:
  kubeletExtraArgs:
    - name: node-ip
      value: 10.218.65.21
```

**Do not use `/etc/default/kubelet` for this.** It is a dpkg conffile owned by the `kubelet`
package, so creating it before `apt-get install kubelet` runs produces a conffile conflict during
step 10. kubeadm's own systemd drop-in says as much: *"This is a file that the user can use for
overrides of the kubelet args as a last resort. Preferably, the user should use the
.NodeRegistration.KubeletExtraArgs object in the configuration files instead."* kubeadm writes the
flag into `/var/lib/kubelet/kubeadm-flags.env`, which it owns outright.

Note the field shape: in `v1beta4` `kubeletExtraArgs` is a **list of `name`/`value` objects**, not
a map. It was a map in earlier versions, and the old form is silently wrong.

### Set your values

Edit the `param:` block in **all three** files in `1-lima/`:

```yaml
param:
  nodeIP: "10.218.65.21"
  prefix: "24"
  gateway: "10.218.65.1"
  dns: "103.94.168.168, 8.8.8.8, 1.1.1.1"
```

Each file carries its own `nodeIP`, already set to `.21`, `.22` and `.23`. The other three values
must be correct and identical in all three files.

---

## 6. Start the control plane VM

Validate first. This catches field and indentation mistakes immediately, rather than part-way
through a multi-minute image download:

```bash
limactl validate 1-lima/control-plane-01.yaml
```

```bash
limactl start --yes 1-lima/control-plane-01.yaml
```

The instance takes its name from the filename, so this creates `control-plane-01`. The first start
downloads the Ubuntu 26.04 cloud image — allow several minutes.

`--yes` accepts the configuration without an interactive menu. Drop it if you want to review the
template first.

```bash
limactl list
```

`Running`.

---

## 7. Verify the static address

**This step decides whether the whole approach works on your network.** Do not continue past it.

**On control-plane-01:**

```bash
ip -4 -br addr
```

You should see **two** addressed interfaces:

| Interface | Expected | Meaning |
|---|---|---|
| `lima0` | `10.218.65.21/24` | The bridged interface, from your `param.nodeIP` |
| `eth0` | `192.168.5.15/24` | Lima's management network. Hardcoded, always present, and how `limactl shell` reaches the guest |

Both are correct. The second is not a misconfiguration and must not be removed — a bridged network
is *added alongside* Lima's own, never instead of it.

If `lima0` has a different address, or none, look at what netplan actually merged — still on
control-plane-01:

```bash
netplan get
```

Then confirm the routing, because this is the part that breaks silently:

```bash
ip route
```

The default route must be via **`10.218.65.1` on `lima0`**, listed ahead of Lima's. It is set at
`metric: 100` against Lima's 200. Two reasons this matters:

- A reply to a client that is **not** on `10.218.65.0/24` follows the default route. If that is
  Lima's management interface, the packet is NAT'd and arrives from the wrong source address, so
  the connection dies. Only same-subnet clients would work.
- Kubelet and kubeadm both derive addresses from the default route's interface.

```bash
ping -c2 10.218.65.1
```

**Do this before going further.** A static default route via a gateway that does not answer leaves
every interface looking correctly configured while the node has no outbound network at all — and
`apt` and image pulls are the first things to fail.

Then the only test that actually matters. **On your MacBook:**

```bash
ping -c2 10.218.65.21
```

If this fails while everything inside the guest looks right, your switch is dropping the guest's
MAC address. That is the scenario the warning at the top was about, and no amount of configuration
inside the VM will fix it.

Nothing needs configuring for the node address at this point — it is set later by the cluster
configuration, in step 11 for the control plane and step 14 for the workers.

---

## 8. Start the two workers

One file per worker, each carrying its own address. Validate first:

```bash
limactl validate 1-lima/worker-01.yaml 1-lima/worker-02.yaml
```

```bash
limactl start --yes 1-lima/worker-01.yaml
```

Wait for it to reach `Running` before starting the next. **Three QEMU guests booting at once on
one Mac will each time out waiting for cloud-init**, and the failure presents as a network problem.

```bash
limactl start --yes 1-lima/worker-02.yaml
```

Each instance takes its name from its filename, so these become `worker-01` and `worker-02` with
no extra flags.

```bash
limactl list
```

Three instances, all `Running`.

**On the Mac mini** — reads all three at once:

```bash
for n in control-plane-01 worker-01 worker-02; do printf '%-18s ' $n; limactl shell $n -- ip -4 -br addr show lima0 | awk '{print $3}'; done
```

`10.218.65.21/24`, `.22/24`, `.23/24`. If any is wrong, that node's `nodeIP` did not take — fix it
before continuing, because an address baked into a cluster is painful to change later.

---

## 9. Set the hostnames

Lima names the guests `lima-control-plane-01` and so on. Kubernetes records nodes under whatever
name `kubeadm` is given, so this is cosmetic — but a node whose hostname disagrees with its
Kubernetes name makes every later log line and selector ambiguous.

**On the Mac mini** — each instance is named the same as the hostname it should have, so one loop
does all three:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- sudo hostnamectl set-hostname $n; done
```

```bash
for n in control-plane-01 worker-01 worker-02; do printf '%-18s ' $n; limactl shell $n -- hostnamectl --static; done
```

---

## 10. Prepare all three nodes

`1-lima/node-prep.sh` does six things, and the cluster will not work without any of them:

| Step | Why |
|---|---|
| `swapoff`, comment `/etc/fstab` | kubeadm's preflight refuses to run with swap enabled |
| Load `overlay` | containerd's snapshotter needs it |
| Load `br_netfilter` | Without it, bridged traffic bypasses netfilter and **Service routing silently does nothing** |
| `bridge-nf-call-iptables=1`, `ip_forward=1` | Same — packets are never seen by the rules meant to redirect them |
| containerd with `SystemdCgroup = true` | On cgroup v2 the kubelet uses the systemd driver while containerd defaults to cgroupfs. Mismatched, **the kubelet dies at startup with an error that never mentions cgroups** |
| Install and hold `kubelet kubeadm kubectl cri-tools` | Without the hold, an unattended upgrade can move the control plane a minor version unprompted |

Lima mounts the Mac mini home directory read-only inside every guest **at the same path**, so the
script runs in place with nothing to copy. Derive that path rather than typing it — you are already
in the repository, and its parent holds the two application repositories:

```bash
export REPO="$(pwd)" && export SRC="$(cd .. && pwd)" && echo "$REPO" && echo "$SRC"
```

**That path must be inside your home directory**, because that is the only thing Lima mounts. Check
it before going further, since the failure is a confusing "no such file or directory" from inside a
guest that looks like the script is missing:

```bash
case "$REPO" in "$HOME"/*) echo "OK — visible inside the VMs" ;; *) echo "PROBLEM — move the repository under $HOME, or add a mount to the VM definitions" ;; esac
```

**On the Mac mini** — copy the script into each node:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl copy 1-lima/node-prep.sh $n:/tmp/node-prep.sh; done
```

**On the Mac mini** — run it on each node in turn. This takes a few minutes per node:

```bash
for n in control-plane-01 worker-01 worker-02; do echo "===== $n"; limactl shell $n -- sudo bash /tmp/node-prep.sh; done
```

Each run ends by printing the installed version and `swap: 0MB`. Both must be correct, on all three.

```bash
for n in control-plane-01 worker-01 worker-02; do printf '%-18s ' $n; limactl shell $n -- kubeadm version -o short; done
```

**All three must report the same version.** kubeadm tolerates a one-minor skew between the control
plane and a kubelet, and nothing else.

---
---

# Part 3 — Build the cluster

## 11. Initialise the control plane

`2-cluster/kubeadm-config.yaml` pins three things that would otherwise be guessed:

- `localAPIEndpoint.advertiseAddress: 10.218.65.21` — without it kubeadm autodetects, and on a
  two-interface node that is a coin flip.
- `nodeRegistration.kubeletExtraArgs` sets `node-ip`, so the kubelet registers the LAN address
  rather than Lima's management address.
- `apiServer.certSANs` includes `127.0.0.1` and `localhost`, so you can later reach the API server
  through an SSH tunnel without overriding the TLS server name.

**On the Mac mini** — copy the configuration in:

```bash
limactl copy 2-cluster/kubeadm-config.yaml control-plane-01:/tmp/kubeadm-config.yaml
```

**On the Mac mini:**

```bash
limactl shell control-plane-01 -- sudo kubeadm init --config /tmp/kubeadm-config.yaml
```

**Save the `kubeadm join …` line it prints.** Its token expires after 24 hours.

Expect a broken-looking cluster right after this: the node `NotReady`, CoreDNS `Pending`. That is
correct. Kubernetes ships no network plugin, so a fresh control plane always looks like this until
step 13.

---

## 12. Point kubectl at it from the Mac mini

Your Mac is on the same subnet as the nodes and `certSANs` already covers `10.218.65.21`, so no
tunnel is needed:

**On the Mac mini:**

```bash
mkdir -p ~/.kube && limactl shell control-plane-01 -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-mini
```

```bash
export KUBECONFIG=~/.kube/config-mini
```

```bash
kubectl get nodes
```

One node, `NotReady`. Every `kubectl` from here runs on the Mac mini. Keeping this in its own file
rather than merging it into `~/.kube/config` means you cannot accidentally point these commands at
another cluster.

---

## 13. Install Calico

Calico's dataplane must match the mode kube-proxy is running in. If they disagree, two subsystems
write conflicting packet rules and nothing warns you. **Do not read the ConfigMap** — `mode: ""`
means "use the default" and tells you nothing about what that resolved to. Read the startup log:

```bash
kubectl -n kube-system logs -l k8s-app=kube-proxy | grep -i Proxier
```

| Log line | `linuxDataplane` in `2-cluster/calico-installation.yaml` |
|---|---|
| `Using iptables Proxier` | `Iptables` — the shipped value |
| `Using nftables Proxier` | change it to `Nftables` |

On Kubernetes v1.36 this reports iptables. Verify rather than assume; the default has been widely
misreported.

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/tigera-operator.yaml
```

**`create`, not `apply`.** That manifest embeds CRDs large enough to exceed the annotation limit
`kubectl apply` writes, and `apply` fails with `metadata.annotations: Too long`.

```bash
kubectl apply -f 2-cluster/calico-installation.yaml
```

```bash
kubectl -n calico-system get pods -w
```

Calico's operator is a controller, not a bundle of workloads — it reads the `Installation` resource
and generates the DaemonSet itself. If `calico-system` stays empty, read the operator's log rather
than hunting for a DaemonSet that was never written:

```bash
kubectl -n tigera-operator logs -l k8s-app=tigera-operator --tail=30
```

An error loop reading `IPPool is not within the platform's configured pod network CIDR(s)` means
`ipPools[0].cidr` in `2-cluster/calico-installation.yaml` does not match `networking.podSubnet` in
`2-cluster/kubeadm-config.yaml`. They must be identical strings.

```bash
kubectl get nodes
```

`control-plane-01` is now `Ready`, and CoreDNS schedules itself.

### About the encapsulation setting

The shipped value is `encapsulation: VXLANCrossSubnet`.

Pod addresses are invented by Kubernetes — your physical network has no route to them. An overlay
solves that by wrapping each pod packet inside an ordinary node-to-node packet.
`VXLANCrossSubnet` wraps **only when two nodes are on different subnets**. With all three nodes on
one segment, Calico installs plain routes and encapsulates nothing, so there is no per-packet cost
— while staying correct if you later add a node elsewhere.

The pod MTU still drops to 1450 regardless, because Calico sizes interfaces for the case it might
have to handle. You avoid the overhead on the wire; you do not avoid the MTU reduction.

---

## 14. Join the workers

Use the line `kubeadm init` printed, or mint a fresh one:

**On the Mac mini:**

```bash
limactl shell control-plane-01 -- sudo kubeadm token create --print-join-command
```

Rather than a long command line, each worker joins from a configuration file — that is the only
way to set `node-ip`, since `kubeadm join` has no flag for it.

Put the two values from that output into your shell:

```bash
export TOKEN=<TOKEN> HASH=<HASH>
```

Then substitute them into the join file and hand it to the guest. This keeps the token in `/tmp`
inside the VM rather than writing it into a file in this repository:

**On the Mac mini** — fill in the two values and place the file in each worker:

```bash
sed -e "s/<TOKEN>/$TOKEN/" -e "s/<HASH>/$HASH/" 2-cluster/join-worker-01.yaml > /tmp/join-worker-01.yaml && limactl copy /tmp/join-worker-01.yaml worker-01:/tmp/join.yaml
```

```bash
sed -e "s/<TOKEN>/$TOKEN/" -e "s/<HASH>/$HASH/" 2-cluster/join-worker-02.yaml > /tmp/join-worker-02.yaml && limactl copy /tmp/join-worker-02.yaml worker-02:/tmp/join.yaml
```

**On the Mac mini** — the same command for each worker, since the file inside each already carries
that node's own name and address:

```bash
limactl shell worker-01 -- sudo kubeadm join --config /tmp/join.yaml
```

```bash
limactl shell worker-02 -- sudo kubeadm join --config /tmp/join.yaml
```

The file carries the node name, the CRI socket and `node-ip` together, so no `--node-name` flag is
needed. Without a node name the node would register under its hostname, and mismatched names make
every later selector and drain command ambiguous.

```bash
kubectl get nodes -o wide
```

All three `Ready`. New nodes take a minute while Calico starts on them.

**Check the `INTERNAL-IP` column, not just the status.** It must read `10.218.65.21`, `.22` and
`.23`. A node showing `192.168.5.15` joined over Lima's management network — which is the same
address on every node — and pod traffic to it will not work. Such a node must be reset and
re-joined; changing the configuration afterwards does not update an address already registered.

**On the Mac mini**, naming the affected node:

```bash
limactl shell worker-01 -- sudo kubeadm reset -f
```

---

## 15. Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
```

Wait for the webhook before applying the pool. `IPAddressPool` is validated by a webhook MetalLB
serves itself, so applying too early fails with a connection refused against
`metallb-webhook-service`:

```bash
kubectl -n metallb-system wait --for=condition=available deploy/controller --timeout=180s
kubectl -n metallb-system wait --for=condition=ready pod -l component=speaker --timeout=180s
```

```bash
kubectl apply -f 2-cluster/metallb-pool.yaml
```

The pool sets `autoAssign: false`, so a Service receives an address only when it asks for one by
annotation. Without that, the first `type: LoadBalancer` Service to appear silently takes the first
address in the pool.

---

## 16. Install the Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```

Gateway API is not part of Kubernetes. Without these CRDs the `Gateway` and `HTTPRoute` kinds do
not exist, and Traefik's provider has nothing to watch — it starts cleanly and routes nothing.

---

## 17. Install cert-manager and create the private CA

Certificates are issued and renewed from a CA created inside the cluster. Nothing is generated by
hand and renewal is automatic.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml
```

```bash
kubectl -n cert-manager wait --for=condition=available deploy --all --timeout=180s
```

**Wait for that.** cert-manager validates its own resources through an admitting webhook, so
applying an `Issuer` or `Certificate` too early fails with a connection refused against
`cert-manager-webhook`.

```bash
kubectl apply -f 2-cluster/cert-manager-ca.yaml
```

Three objects, and the ordering between them is the interesting part:

| Object | Purpose |
|---|---|
| `ClusterIssuer/selfsigned-bootstrap` | Can only sign self-signed certificates. Exists solely to sign the CA below |
| `Certificate/cluster-ca` | `isCA: true`, valid 10 years. Produces the Secret `cluster-ca-tls` holding the CA key and certificate |
| `ClusterIssuer/cluster-ca` | Signs everything else, reading that Secret |

A CA has to be signed by something and there is nothing above it, so cert-manager bootstraps by
having a self-signed issuer sign the CA once. After that the CA signs everything and the bootstrap
issuer is never used again.

```bash
kubectl get clusterissuer
```

Both `READY: True`. If `cluster-ca` is not ready, the `cluster-ca-tls` Secret does not exist yet —
check the Certificate:

```bash
kubectl -n cert-manager describe certificate cluster-ca
```

Now the server certificate. It must live in the same namespace as the Gateway:

```bash
kubectl create namespace traefik
```

```bash
kubectl apply -f 2-cluster/cert-manager-gateway-cert.yaml
```

```bash
kubectl -n traefik get certificate,secret gateway-tls
```

`READY: True`, and cert-manager creates the Secret itself — there is no `kubectl create secret tls`
step anywhere in this build, and the Secret is regenerated automatically before expiry.

### Where the hostnames come from

The hostnames look unusual: `planpal.10-218-65-27.traefik.me`. `traefik.me` is a public wildcard
DNS service — any name of the form `<ip-with-dashes>.traefik.me` resolves to that address, from any
resolver, with nothing to configure. It replaces editing `/etc/hosts` on every client machine. The
names resolve globally but the address is private, so only machines on your network can reach it.

Avoid `.local`, which is reserved for mDNS and resolved by Bonjour before `/etc/hosts` on macOS,
and `.test`, which some OAuth providers reject for not being a public TLD.

---

## 18. Install Traefik

```bash
kubectl apply -f 2-cluster/traefik/
```

| File | Contents |
|---|---|
| `00-rbac.yaml` | Namespace, ServiceAccount, ClusterRole, ClusterRoleBinding |
| `01-deployment.yaml` | The Traefik pod and its command-line flags |
| `02-service.yaml` | `type: LoadBalancer`, requesting the MetalLB address |
| `03-gateway.yaml` | `GatewayClass` and `Gateway` |

```bash
kubectl -n traefik get svc traefik
```

`EXTERNAL-IP` must show `10.218.65.27`. `<pending>` means MetalLB never saw the annotation — check
the pool applied and that the address is inside it.

```bash
kubectl -n traefik get gateway traefik-gateway
```

`PROGRAMMED: True`. If it stays `Unknown`, the usual cause is the **status** RBAC rule: reading
Gateway objects and writing their status are separate permissions, and without the second Traefik
can see the Gateway but never report on it. The symptom looks exactly like Traefik ignoring the
Gateway.

### Four details in these manifests

**Ports 8000 and 8443, not 80 and 443.** The Traefik image runs as a non-root user, and Linux
forbids non-root processes from binding ports below 1024. The Service maps 80 → 8000 and
443 → 8443, which is what makes it look like the standard ports from outside. The Gateway's
listener ports are the **container** ports, so they read 8000 and 8443; anything a client is told,
such as a redirect target, must use the **published** ports.

**`--providers.kubernetesGateway=true`**, not `kubernetesIngress`. Both providers exist, and
enabling the wrong one leaves the Gateway without an address and no error explaining why.

**`allowedRoutes.namespaces.from: All`** on each listener. The default is `Same`, meaning the
Gateway accepts routes only from its own namespace — so every route in an application namespace is
silently rejected.

**The HTTP-to-HTTPS redirect uses `to=:443`, not `to=websecure`.** Both are valid syntax and only
one works. Given an entryPoint *name*, Traefik puts that entryPoint's own address in the `Location`
header — and `websecure` listens on 8443, the container port. The client is told to go to
`https://host:8443/`, which nothing outside the cluster can reach. A bare port is used verbatim, and
443 is the default for `https`, so Traefik omits it.

The redirect is a property of the entryPoint, not of any route, and is applied before routing — so
it fires for every request on port 80 whether or not a route matches. The readiness and liveness
probes are unaffected: `/ping` is served on Traefik's internal entryPoint on port 8080, a separate
listener with no redirection.

---

## 19. Verify the cluster end to end

**On your MacBook** — this is the check that matters, because it comes from a different subnet:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -k https://10.218.65.27/
```

**`404` is success here.** Traefik is answering and no route matches yet. A timeout means the
announcement is not reaching you.

`-k` is needed until step 20. Without it you get
`SSL certificate problem: unable to get local issuer certificate`, which confirms TLS is
terminating correctly — the certificate is valid, its issuer is simply not trusted yet.

```bash
curl -sS -D - -o /dev/null http://planpal.10-218-65-27.traefik.me/ | grep -iE '^(HTTP/|location:)'
```

`301` and a `Location` with **no port**. A `Location` containing `:8443` means the redirect targets
the entryPoint name rather than `:443`.

### Watch the L2 announcement

This is the mechanism the whole cluster's reachability rests on, and it is worth seeing directly.

MetalLB does not assign the address to any interface. One node is elected, and its speaker answers
ARP requests for an address it does not own. Force a resolution and read the result:

```bash
ping -c1 -W1 10.218.65.27 >/dev/null 2>&1; arp -n 10.218.65.27
```

**The ping fails, and that is expected.** A LoadBalancer address exists only on the ports its
Service declares, so ICMP matches nothing. The ping is only there to trigger ARP.

Turn that MAC address into a node name. **On the Mac mini:**

```bash
MAC=$(arp -n 10.218.65.27 | awk '{print $4}'); for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- ip -o link show lima0 | grep -qi "$MAC" && echo "announced by $n ($MAC)"; done
```

Confirm no interface actually holds the address:

Confirm no interface actually holds it. **On the Mac mini**, naming the node above:

```bash
limactl shell worker-01 -- ip -4 addr show | grep 10.218.65.27 || echo "not on any interface"
```

Watch the exchange live, then hit the address from another terminal:

```bash
sudo tcpdump -i en0 -n arp host 10.218.65.27
```

One request, exactly one reply, and the other two nodes silent. Delete the announcing node's
speaker pod and you will see a **gratuitous ARP** as the new leader claims the address unprompted —
which is how failover works without clients doing anything.

**Run these from the Mac mini, not from a node and not from the MacBook.** The mini is on the
nodes' own subnet, which is what makes ARP meaningful; the MacBook is a router hop away and would
never ARP for this address. And on a cluster node, kube-proxy intercepts traffic to a
Service address before a packet is built, so no ARP happens and the table stays empty even when
everything works.

---

## 20. Trust the CA

The CA is private, so nothing trusts it until you say so. **Both Macs need it** — the mini so
`docker push` works in part 4, the MacBook so your browser stops warning.

**On the Mac mini** — export it, then trust it locally:

```bash
kubectl -n cert-manager get secret cluster-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cluster-ca.crt
```

One import covers every certificate the cluster will ever issue, including new hostnames and every
renewal. That is the whole reason for running a CA rather than issuing standalone self-signed
certificates.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://10.218.65.27/
```

`404`, now with no `-k`.

**On your MacBook** — copy `cluster-ca.crt` across however you like, then:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cluster-ca.crt
```

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://10.218.65.27/
```

Same `404`, no `-k`. Now a browser on the MacBook will open the application without a warning.

### Optionally, run kubectl from the MacBook too

The API server's certificate already covers `10.218.65.21`, so nothing else is needed. **On the Mac
mini**, print the kubeconfig and copy the output across:

```bash
cat ~/.kube/config-mini
```

**On your MacBook**, save it as `~/.kube/config-mini` and:

```bash
export KUBECONFIG=~/.kube/config-mini && kubectl get nodes
```

That file embeds an administrator credential — treat it as a password.

The cluster is complete. Part 4 is optional.

---
---

# Part 4 — Deploy the application

Three things a bare `kubeadm` cluster lacks have to be filled in first: dynamic storage, a metrics
pipeline, and a reachable image registry.

## 21. A StorageClass

`kubeadm` installs no storage provisioner, so any PersistentVolumeClaim stays `Pending` forever
with no event explaining why.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
```

The manifest does not mark itself default, and claims that omit `storageClassName` will not bind
without it:

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

```bash
kubectl get storageclass
```

Wants `local-path (default)`.

`local-path` writes to a directory on whichever node the pod lands on, and the resulting volume
carries a **node affinity** pinning it there. A StatefulSet whose node is drained will not
reschedule — its volume physically cannot follow. Fine here, and worth knowing before draining a
node that holds a database.

---

## 22. metrics-server

Without it, `kubectl top` fails and every HorizontalPodAutoscaler sits at `<unknown>` forever,
taking no action and reporting no error that names the cause.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
```

It will not become ready yet. On a kubeadm cluster it fails to scrape, logging
`x509: cannot validate certificate for <node ip> because it doesn't contain any IP SANs`.

That is not a misconfiguration. `kubeadm` gives each kubelet a **self-signed** serving certificate,
because issuing properly signed ones requires each kubelet to request a certificate and someone to
approve it. metrics-server refuses to trust an issuer it cannot verify, and says so rather than
scraping anyway.

```bash
kubectl -n kube-system patch deploy metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Read that flag correctly.** It does not disable TLS. The connection to each kubelet is still
encrypted; metrics-server simply stops verifying who is on the other end. The exposure is that
something able to impersonate a kubelet on the node network could feed false metrics. For a lab on
one segment that is an acceptable trade. The production answer is `serverTLSBootstrap: true` in the
kubelet configuration plus approving the resulting certificate requests, and re-approving them on
every rotation.

```bash
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
```

```bash
kubectl top nodes
```

Real numbers. `--metric-resolution` defaults to 15s and the autoscaler re-evaluates every 15s, so a
scaling decision can legitimately take **up to about 30 seconds** to appear. Do not conclude an
autoscaler is broken before then.

One prerequisite that silently disables autoscaling: **an HPA targeting CPU needs a CPU `requests`
value on every container in the pod.** Utilisation is a percentage *of the request*, so with no
request there is no denominator. Every workload in `3-app/` sets one.

---

## 23. The in-cluster registry

```bash
kubectl apply -f 2-cluster/registry.yaml
```

The registry is a ClusterIP Service exposed through the same Gateway and the same address as the
application, on its own hostname — so image pulls happen over HTTPS and there is one address for
the whole cluster.

```bash
curl -sSk https://registry.10-218-65-27.traefik.me/v2/_catalog
```

`{"repositories":[]}` exercises DNS, the address, the L2 announcement, Traefik, TLS and the
registry in one request. Get it green before continuing — everything downstream depends on it.

`-k` is required here and only here; nothing trusts the CA yet from the nodes' point of view, which
is step 24's job.

**Traefik's `readTimeout` must be 0 for pushes to work**, and `2-cluster/traefik/01-deployment.yaml`
sets it. The default is 60 seconds and it bounds reading the *entire* request body, so pushing a
container layer through the proxy routinely exceeds it — and fails as a truncated blob upload
rather than as an obvious timeout.

---

## 24. Teach the nodes and the Mac mini to trust the registry

The registry is served over HTTPS by a certificate the in-cluster CA signed. Two sets of machines
need that CA: **every node**, because containerd pulls the images, and **whichever machine builds
them**, because Docker pushes them.

```bash
kubectl -n cert-manager get secret cluster-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

On every node — containerd reads this directory on each pull, so no restart is needed:

**On the Mac mini** — copy the CA into each node:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl copy cluster-ca.crt $n:/tmp/cluster-ca.crt; done
```

**On the Mac mini** — install it on each node:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- sudo mkdir -p /etc/containerd/certs.d/registry.10-218-65-27.traefik.me && limactl shell $n -- sudo cp /tmp/cluster-ca.crt /etc/containerd/certs.d/registry.10-218-65-27.traefik.me/ca.crt && echo "$n done"; done
```

`node-prep.sh` already pointed containerd's `config_path` at `/etc/containerd/certs.d`, which is
what makes that directory take effect. No `hosts.toml` is needed alongside the `ca.crt` — with no
`hosts.toml` present, containerd falls back to Docker's certificate-file pattern and reads `*.crt`
there as CA certificates.

On containerd 2.x this is the **only** mechanism that works. Pulls are delegated to the transfer
service by default, and that service supports only the registry `config_path` — the older
`config.toml` keys `registry.mirrors` and `registry.configs.<host>.tls` are ignored for CRI pulls,
silently.

Docker uses the same convention at a different path — and on macOS that path is **not** the one
Docker's own documentation gives you. `/etc/docker/certs.d` is where a Linux daemon reads. On a Mac
the daemon runs inside a VM, and both OrbStack and Docker Desktop expose `~/.docker/certs.d` to it
instead. A directory created under `/etc` on the Mac is never looked at, and the failure is a
`docker push` rejected with `x509: certificate signed by unknown authority` — which reads like a
wrong CA rather than a path nothing consults.

**On whichever machine builds the images:**

```bash
mkdir -p ~/.docker/certs.d/registry.10-218-65-27.traefik.me && cp cluster-ca.crt ~/.docker/certs.d/registry.10-218-65-27.traefik.me/ca.crt
```

Confirm what the daemon itself sees, rather than trusting either path. This prints the VM's own
view of the directory, so it is correct on OrbStack and Docker Desktop alike:

```bash
docker run --rm -v /etc/docker/certs.d:/c alpine ls -la /c
```

On OrbStack that `/etc/docker/certs.d` inside the VM is a symlink to
`/mnt/mac/Users/<you>/.docker/certs.d` — the Mac-side directory you just wrote. Your registry
hostname must appear in the listing.

```bash
curl -sS --cacert cluster-ca.crt https://registry.10-218-65-27.traefik.me/v2/_catalog
```

`{"repositories":[]}` means the chain verifies. Two failures worth telling apart:

- `curl: (60) unable to get local issuer certificate` **without** `--cacert` is expected. Error 60
  is raised after a completed TLS handshake, so DNS, the address, Traefik and the certificate's
  names are all working. `curl` reads the system trust store; Docker and containerd read `certs.d`.
- The same error **with** `--cacert` means the CA file is wrong, and `docker push` will fail with
  `x509: certificate signed by unknown authority`.

**Do not serve this registry over plain HTTP instead.** With the HTTP-to-HTTPS redirect in place, a
client speaking HTTP gets a 301 — and Go's HTTP client, which both Docker and containerd use,
rewrites a 301 from POST to GET and drops the request body. A blob upload would fail in a way that
reads like a corrupt push rather than a redirect.

---

## 25. Build and push the twelve images

Tag each image with the registry hostname **at build time** — a Docker image's name *is* its push
destination, so there is no separate upload step to get wrong.

The application's two source repositories sit beside this one, at `$SRC` from step 10:

```bash
ls "$SRC"
```

Wants `planpal-backend-learner7-ch4` and `planpal-frontend-learner7-ch4` among the entries.

Six HTTP services, from `planpal-backend-learner7-ch4/`:

```bash
cd "$SRC/planpal-backend-learner7-ch4" && for s in auth meeting calendar notification ai slack; do docker build --target service-http --build-arg BIN=planpal-$s-server -t registry.10-218-65-27.traefik.me/planpal-$s-server:dev . ; done
```

Four workers:

```bash
for s in meeting calendar notification ai; do docker build --target service-worker --build-arg BIN=planpal-$s-worker -t registry.10-218-65-27.traefik.me/planpal-$s-worker:dev . ; done
```

The migration job:

```bash
docker build --target migrate -t registry.10-218-65-27.traefik.me/planpal-migrate:dev .
```

Eleven builds sound slow but are not. They share one Dockerfile whose builder stage compiles the
whole Rust workspace; only the final `COPY` of one binary differs, so the compile happens once and
the other ten are near-instant.

The frontend is different, and it is the one most easily got wrong:

```bash
cd "$SRC" && docker build --build-arg NEXT_PUBLIC_API_URL=https://planpal-api.10-218-65-27.traefik.me/api/v1 -t registry.10-218-65-27.traefik.me/planpal-web:dev ./planpal-frontend-learner7-ch4
```

Next.js inlines `NEXT_PUBLIC_*` variables into the JavaScript bundle at **build** time, so the API
address is baked into the image. Putting it in a ConfigMap changes nothing. Change that hostname and
this image must be rebuilt. The eleven Rust images have no such property — they read every hostname
from the ConfigMap at startup.

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^registry.10-218-65-27.traefik.me/' | xargs -n1 docker push
```

```bash
curl -sS --cacert "$REPO/cluster-ca.crt" https://registry.10-218-65-27.traefik.me/v2/_catalog
```

Twelve repositories. If a push fails partway with a timeout rather than a TLS error, revisit
Traefik's `readTimeout` in step 23.

**After any later rebuild, push again.** `:dev` is a mutable tag: rebuilding updates the local image
and leaves the registry holding the old content, with nothing warning you. The manifests set
`imagePullPolicy: Always`, so once the push lands a `rollout restart` picks it up.

```bash
cd "$REPO"
```

---

## 26. Render the Secret

The application's credentials are not in this repository. `3-app/make-secrets.sh` renders
`3-app/05-secrets.yaml` from the two source repositories' `.env` files. Both the inputs and the
output are gitignored.

Copy each repository's `.env.example` to `.env` and fill it in first. The script refuses to run on
a missing file and reports any value that still looks like a placeholder. It prints key *names*
only, never values.

```bash
bash 3-app/make-secrets.sh
```

`3-app/secrets.example.yaml.tpl` is the committed reference showing every key the application
expects and what each is for.

Two values are worth checking rather than assuming, because both have caused a failed deployment:

- The seed admin password must meet the application's minimum length. A short one fails validation
  rather than authentication, which reads as a database problem.
- `POSTGRES_PASSWORD` is read **only when the data directory is empty**. On any later boot it is
  ignored, so rotating it in the Secret does nothing to a running database — that takes an
  `ALTER ROLE`.

---

## 27. Apply the application

```bash
kubectl apply -f 3-app/
```

The files are numbered so a single directory apply orders correctly: namespace and PriorityClass,
then ServiceAccount, then Secret and ConfigMap, then the data tier, then Jobs, services and routes.
`kubectl` applies a directory in filename order, which is the only reason that works — a pod
referencing a PriorityClass that does not exist yet is rejected outright.

```bash
kubectl -n planpal wait --for=condition=complete job/planpal-migrate --timeout=300s
```

**Expect `CrashLoopBackOff` on the application pods for the first minute.** Postgres, NATS and (for
the workers) Redis are hard startup dependencies — each connection is asserted during bootstrap, so
whichever service starts first exits and is restarted until its dependencies answer. That is the
system working, and it needs no intervention.

```bash
kubectl -n planpal get pods -w
```

A `rollout restart` is **not** part of a normal deploy here. It is the remedy for one specific
situation: the NATS JetStream stream being lost while services are already running, because stream
setup runs once per process at startup and nothing recreates it. The volume in `3-app/12-nats.yaml`
prevents that.

---

## 28. Verify the application

```bash
kubectl -n planpal get pods -o wide
```

Everything `Running`, and `auth-server` should show two pods on two different nodes — that is the
spread constraint working.

```bash
curl -sS https://planpal-api.10-218-65-27.traefik.me/api/v1/health
```

```bash
kubectl -n planpal exec sts/nats -- wget -qO- 'http://127.0.0.1:8222/jsz?streams=1' | grep -E '"streams"|"consumers"'
```

Wants `streams: 1` and `consumers: 8`. Note `sts/nats`, not `deploy/nats`. A stream count of zero
alongside healthy pods is the stream-loss case above.

```bash
kubectl -n planpal get pvc
```

Two `Bound` claims — `data-postgres-0` and `data-nats-0`. Redis has none by design: nothing durable
is stored in it. `Pending` means the StorageClass from step 21 is missing or not default.

```bash
kubectl -n planpal get pods -l "app in (postgres,redis,nats)" -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,PRIORITY:.spec.priority'
```

`Guaranteed` and `1000000` on all three. Under node memory pressure the kubelet ranks eviction
candidates by whether usage exceeds **requests**, then by **priority** — so the data tier sets
requests equal to limits, which keeps it out of the first group entirely. Priority alone would only
win ties inside it.

```bash
kubectl -n planpal get hpa
```

`TARGETS` must show a real percentage. `<unknown>` means metrics-server is not serving, or a
container in the target has no CPU request.

```bash
kubectl -n planpal get networkpolicy
```

```bash
kubectl -n planpal get pods -l "app in (postgres,redis,nats)"
```

Three pods. A NetworkPolicy whose selector matches nothing is indistinguishable from one that is
working, so confirm the selector finds them. Note that policy is only as real as the CNI behind it —
several plugins accept and list the object while enforcing nothing. Calico enforces it, which is why
it is used here.

Finally, open `https://planpal.10-218-65-27.traefik.me` in a browser. No certificate warning, if you
did step 20.

---
---

# Teardown

Four levels, least to most destructive. Pick the shallowest one that solves your problem.

## Stop the VMs, keep everything

Frees CPU and memory. `socket_vmnet` exits once the last instance stops, so there is nothing to
clean up on the Mac mini.

```bash
for n in control-plane-01 worker-01 worker-02; do limactl stop $n; done
```

Add `-f` only if a graceful stop hangs — it is equivalent to pulling the power on the guest.

Starting them again brings the cluster back as it was. The static addresses return on their own,
because the netplan drop-in lives in the guest filesystem.

## Reset the cluster, keep the VMs

Wipes Kubernetes from all three nodes without deleting the machines:

**On the Mac mini** — workers first, control plane last:

```bash
for n in worker-01 worker-02 control-plane-01; do limactl shell $n -- sudo kubeadm reset -f; limactl shell $n -- sudo rm -rf /etc/cni/net.d; done
```

`kubeadm reset` leaves firewall rules behind, which will confuse the next install on the same node:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- sudo bash -c 'iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X'; done
```

Note that this does **not** remove the directories `local-path` wrote, so any database contents
survive. Delete them by hand if you want the disk back.

## Reset a guest to freshly-provisioned

Returns a VM to its post-install state without re-downloading the image or re-creating the
instance. Useful after a botched `kubeadm init`:

```bash
limactl factory-reset control-plane-01
```

## Delete the VMs

Removes each instance and its directory under `~/.lima/`, which is where the disk lives — so this
destroys the nodes and everything on them:

```bash
for n in control-plane-01 worker-01 worker-02; do limactl delete -f $n; done
```

`-f` kills a running instance first, so you do not need to stop them separately.

```bash
limactl list
```

```bash
ls ~/.lima
```

`_config` and `_cache`, and none of the three instances.

**Deleting instances does not reclaim the downloaded cloud image.** It stays in `~/.lima/_cache` so
the next VM starts quickly, which is usually what you want. To reclaim it:

```bash
du -sh ~/.lima/_cache && limactl prune
```

## Remove Lima and socket_vmnet from the Mac mini

Only when you are done with this approach entirely. Delete every instance first — the sudoers rule
and the daemon binary are shared, and removing them out from under a running instance leaves it
unable to start.

```bash
limactl list -q | xargs -r limactl delete -f
```

```bash
sudo rm -f /etc/sudoers.d/lima
```

```bash
sudo rm -rf /opt/socket_vmnet
```

```bash
brew uninstall lima qemu
```

```bash
rm -rf ~/.lima
```

That last one discards Lima's own state, including `_config/networks.yaml` and the SSH keypair it
generated.

Remove the CA from your keychain, or the machine keeps trusting a CA whose private key is gone:

```bash
sudo security delete-certificate -c cluster-ca /Library/Keychains/System.keychain
```

## Two things that are not on this machine

**A DHCP reservation or switch-port exception** for a guest's MAC address lives on the *network*, so
it outlives the VM. Tell whoever configured it, or the next device presenting that MAC inherits
whatever was set up for it.

**Registered OAuth redirect URIs**, if you configured any for the application, still point at
addresses that no longer answer.

---

# Troubleshooting

Indexed by symptom.

### Part 1 — the Mac mini

| Symptom | Cause |
|---|---|
| VM start fails, missing binary | `brew install qemu` — Lima does not depend on it |
| Template rejected, unknown field | Lima older than 2.0.0 |
| Warning about `template://` locators | Use `template:` with a single colon; the `//` form is pre-2.0 |
| Permission error starting the network | `limactl sudoers` not run, or needs re-running after a Lima upgrade |
| `limactl sudoers` refuses the path | `socket_vmnet` installed somewhere user-writable, such as the Homebrew prefix |

### Part 2 — the VMs

| Symptom | Cause |
|---|---|
| `lima0` has no address | Drop-in not applied — check `netplan get`; or bridging onto an interface with no link |
| `lima0` has a DHCP address, not the static one | `dhcp4: false` missing, so Lima's `dhcp4: true` still wins |
| Address correct, no outbound network | Static default route via a gateway that does not answer. `ping` the gateway |
| netplan warns permissions are too open | The drop-in is not `0600`; `0644` and `0640` both warn |
| Reachable from the Mac mini, not from the MacBook | Port security on the switch, or bridged onto Wi-Fi |
| Second and third VM time out on boot | Started concurrently. Start them one at a time |
| Locked out of a guest after editing netplan | Lima's management interface or its route was removed. Recover via `limactl` serial console |

### Part 3 — the cluster

| Symptom | Cause |
|---|---|
| kubelet fails at startup, no mention of cgroups | containerd `SystemdCgroup = false` against a cgroup v2 host |
| dpkg conffile prompt for `/etc/default/kubelet` during node-prep | Something created that file before `apt-get install kubelet`. It is a package-owned conffile — set `node-ip` via `nodeRegistration.kubeletExtraArgs` instead |
| Nodes `NotReady`, CoreDNS `Pending` | Normal before a CNI is installed |
| `IPPool is not within the platform's configured pod network CIDR(s)` | `ipPools[0].cidr` ≠ `networking.podSubnet` |
| `metadata.annotations: Too long` installing the operator | Used `apply` instead of `create` |
| Node's `INTERNAL-IP` is `192.168.5.15` | Joined over Lima's management network. Reset and re-join that node |
| Pods run, Services never connect | `br_netfilter` not loaded, or `bridge-nf-call-iptables` unset |
| `IPAddressPool` rejected, connection refused | Applied before the MetalLB webhook was ready |
| `EXTERNAL-IP` stuck `<pending>` | No pool, address outside the pool, or `autoAssign: false` with no annotation |
| Address unreachable from clients, cluster healthy | Pool outside the clients' subnet, so nothing ARPs for it |
| Address does not respond to ping | Expected — it exists only on its declared Service ports |
| `kubeadm join` rejected | Token expired after 24 hours. Mint a new one |
| `Certificate` rejected, connection refused to `cert-manager-webhook` | Applied before cert-manager's webhook was ready |
| `ClusterIssuer/cluster-ca` not `READY` | The `cluster-ca-tls` Secret does not exist — check `Certificate/cluster-ca` |
| Gateway `PROGRAMMED: Unknown` | Missing `*/status` RBAC verbs |
| Gateway `ResolvedRefs: False` | `certificateRefs` name does not match the Certificate's `secretName` |
| Routes in other namespaces ignored | Listener missing `allowedRoutes.namespaces.from: All` |
| HTTP redirects to `https://host:8443/`, then hangs | Redirect targets the entryPoint name instead of `:443` |
| Browser warns despite cert-manager | The CA has not been imported on that machine |

### Part 4 — the application

| Symptom | Cause |
|---|---|
| PVC stuck `Pending`, no events | No default StorageClass |
| `kubectl top` → `error: Metrics API not available` | metrics-server not installed or not yet ready |
| metrics-server never Ready, logs show `doesn't contain any IP SANs` | `--kubelet-insecure-tls` not patched on |
| HPA `TARGETS` stuck at `<unknown>` | metrics-server not serving, or a container has no CPU request |
| `curl: (60) unable to get local issuer certificate` | Expected without `--cacert` — `curl` reads the system store, not `certs.d` |
| `docker push`: `x509: certificate signed by unknown authority` | CA missing from `~/.docker/certs.d/<host>/ca.crt`. On macOS `/etc/docker/certs.d` is the wrong path — the daemon is in a VM and never reads it |
| Pod `ErrImagePull` with an x509 error | CA missing from `/etc/containerd/certs.d/<host>/ca.crt` on that node |
| `docker push` uploads, then fails partway | Traefik `readTimeout` not 0 |
| Rebuilt an image, cluster runs the old code | Rebuild updates the local image only. Push again |
| Frontend loads but calls the wrong API host | Web image built with a stale `NEXT_PUBLIC_API_URL`. Rebuild and push |
| All pods `Running`, nothing gets processed | JetStream stream lost after startup. `rollout restart deployment` |
| `FATAL: sorry, too many clients already` | Replica count × per-process pool exceeded Postgres `max_connections` |
| Pod rejected: `no PriorityClass ... was found` | `02-priorityclass.yaml` applied after the workloads |
| Data-tier pod shows `Burstable`, not `Guaranteed` | A `requests`/`limits` pair does not match exactly |
| `kubectl drain` hangs on a data-tier node | `local-path` volume is pinned there; the pod cannot move. Uncordon |
| NetworkPolicy listed but not enforcing | Selector matches no pods — check the label key, not the values |
| Postgres password change had no effect | It is read only when the data directory is empty |
