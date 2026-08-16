# mac-mini — PlanPal on a three-node Kubernetes cluster

A runbook for standing up our cluster on the Mac mini and deploying PlanPal to it.

Three Lima VMs become a real `kubeadm` cluster with Calico, MetalLB, Traefik + Gateway API, a
private CA, and an in-cluster image registry. PlanPal then runs on it — 12 images, Postgres,
Redis, NATS, an autoscaler — reachable from any machine on the office LAN.

**Every address below is already committed. You do not edit any manifest.**

| | |
|---|---|
| Frontend | https://planpal.10-218-65-27.traefik.me |
| API | https://planpal-api.10-218-65-27.traefik.me |
| Registry | https://registry.10-218-65-27.traefik.me |
| Mac mini | `10.218.65.20`, static. The Lima host — not a cluster node |
| Nodes | `10.218.65.21` control-plane-01, `.22` worker-01, `.23` worker-02 |
| Ingress | `10.218.65.27` (MetalLB) |

Every "why" behind these choices, plus a troubleshooting table indexed by symptom, is in
**[docs/BUILD-GUIDE.md](docs/BUILD-GUIDE.md)**. Read that when something does not match; this file
is the happy path only.

---

## Two machines, and which one runs what

**Every command block below is tagged with the machine it runs on.** Get this wrong and you will
chase a failure that is really just a command typed in the wrong terminal.

| Machine | What lives on it | What it does |
|---|---|---|
| 🖥️ **Mac mini** — `10.218.65.20`, account `ladmin` | This repo only | Runs Lima and the three VMs. Builds the cluster, Parts 1–4. No Docker, no application source |
| 💻 **MacBook** | This repo **plus** `planpal-backend-learner7-ch4` and `planpal-frontend-learner7-ch4` | Runs Docker. Builds and pushes the images, renders the Secret, deploys the app, Part 5 |

The Mac mini never sees the application source or the `.env` files. The MacBook never runs
`limactl`. Both run `kubectl` against the same cluster.

A few commands are tagged 🖥️ **Mac mini** but end with `limactl shell <node> -- …` — you type them
on the mini, and they execute inside that VM.

**Always log into the mini as `ladmin`.** Lima keeps its VMs in that account's `~/.lima`, so
whoever ran `limactl start` is the only one who can stop, shell into, or delete them — another
account gets an empty `limactl list` even while the cluster is running fine. The commands that need
elevation already say `sudo`.

Anyone who only needs to *use* the cluster does not need that account at all. Give them a copy of
`~/.kube/config-mini` and they get full `kubectl` from their own machine, exactly as the MacBook
does in Part 5.

---

## Before you start

### On the Mac mini

- Apple Silicon, macOS 14+, 16 GB RAM, ~40 GB free disk
- **Wired Ethernet.** Many Wi-Fi adapters silently refuse to bridge a second MAC address
- **Remote Login on.** System Settings → General → Sharing → Remote Login. Step 22 copies the
  kubeconfig to the MacBook over `scp`, and that is the one transfer between the two machines
- **A static `10.218.65.20`**, set in System Settings → Network → Ethernet → Details → TCP/IP →
  Configure IPv4: Manually. Not a DHCP lease. Nothing in this repo configures the mini's own
  address — the VMs get theirs from `1-lima/`, the host does not
- Six further addresses free on that subnet

🖥️ **Mac mini** — confirm the host address first, then that the six the cluster claims are idle:

```bash
ipconfig getifaddr en0
```

Must print `10.218.65.20`.

🖥️ **Mac mini**

```bash
for i in 21 22 23 27 28 29; do printf "  .%s " $i; ping -c1 -W1 10.218.65.$i >/dev/null 2>&1 && echo IN USE || echo free; done
```

All six must say `free`. A static address takes no DHCP lease, so nothing else on the network will
warn you about a collision. If any is taken, or the mini is on a different subnet, stop and read
[docs/BUILD-GUIDE.md](docs/BUILD-GUIDE.md) — it lists every file each address lives in.

Nothing else is needed up front — step 0 installs Homebrew and clones this repo.

### On the MacBook

- On the same LAN as the mini
- **Docker already installed and running** — OrbStack or Docker Desktop, either is fine. Both run
  the daemon inside a Linux VM and both read registry CAs from `~/.docker/certs.d`, so nothing
  below changes between them. The mini does not need Docker at all
- All three repos side by side. `make-secrets.sh` and the image builds both depend on this layout:

```
your-workdir/
├── mac-mini/          ← this repo again
├── planpal-backend-learner7-ch4/
└── planpal-frontend-learner7-ch4/
```

💻 **MacBook**

```bash
git clone git@github.com:chalvinwz/mac-mini.git && cd mac-mini
```

### Re-running steps

Almost everything here is safe to run twice — `kubectl apply`, `node-prep.sh`, `make-secrets.sh`,
the image builds, and all of step 0 are written to be idempotent. Four are not:

| Step | Re-running it | What to do instead |
|---|---|---|
| 9 `kubeadm init` | Preflight fails — the port is bound and `/etc/kubernetes` is populated | `limactl shell control-plane-01 -- sudo kubeadm reset -f` first |
| 12 `kubeadm join` | Same, on that worker | `limactl shell worker-01 -- sudo kubeadm reset -f` first |
| 11 `kubectl create -f …tigera-operator.yaml` | `AlreadyExists` | Harmless. It has to be `create` — `apply` fails on the CRD annotation size |
| 20 metrics-server patch | Appends a second `--kubelet-insecure-tls` | Harmless, last flag wins. Check with `kubectl -n kube-system get deploy metrics-server -o jsonpath='{..args}'` |

### Shell variables

Each machine keeps its own. If you open a new terminal part-way through, set them again.

🖥️ **Mac mini**

```bash
cd mac-mini && export KUBECONFIG=~/.kube/config-mini
```

💻 **MacBook** — from step 22 onward, once the kubeconfig has been copied across:

```bash
cd mac-mini && export REPO="$(pwd)" SRC="$(cd .. && pwd)" KUBECONFIG=~/.kube/config-mini
```

---
---

# Part 1 — Prepare the Mac mini

## 0. Install Homebrew and clone this repo

Skip nothing — every block here is guarded, so re-running step 0 on a machine that is already set
up does nothing and reports success.

🖥️ **Mac mini** — installs Homebrew only if it is missing. It will ask for your password, and it
pulls in Apple's Command Line Tools, which is where `git` comes from:

```bash
command -v brew >/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

🖥️ **Mac mini** — on Apple Silicon the installer does **not** put `brew` on your `PATH`; it prints
the line to add and people miss it, then `brew` is "command not found" in the next terminal. This
adds it once and applies it now:

```bash
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

🖥️ **Mac mini**

```bash
brew --version
```

🖥️ **Mac mini** — clone this repo and work from it. Everything from here runs inside `mac-mini/`:

```bash
[ -d mac-mini ] || git clone git@github.com:chalvinwz/mac-mini.git
cd mac-mini
```

## 1. Install Lima and QEMU

🖥️ **Mac mini**

```bash
brew install lima qemu
```

QEMU is a separate package and Lima does not depend on it.

🖥️ **Mac mini**

```bash
limactl --version
```

Must be 2.0.0 or newer.

## 2. Build socket_vmnet from source

Do **not** install this from Homebrew — Lima rejects a binary in a user-writable prefix, because it
runs as root.

🖥️ **Mac mini**

```bash
git clone https://github.com/lima-vm/socket_vmnet.git /tmp/socket_vmnet
```

🖥️ **Mac mini**

```bash
cd /tmp/socket_vmnet && sudo make PREFIX=/opt/socket_vmnet install.bin && cd -
```

That last `cd -` returns you to `mac-mini/`, where everything else runs.

## 3. Grant Lima permission to start the network

🖥️ **Mac mini**

```bash
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

Re-run this after any Lima upgrade.

## 4. Check the interface you are bridging onto

🖥️ **Mac mini**

```bash
ifconfig en0 | grep -E 'status|inet '
```

Wants `status: active` and `inet 10.218.65.20`. `en0` here is the **Mac's** interface, the one the
guests bridge onto — bridging onto an interface with no link produces guests with no network and no
error explaining why. If the mini ends up on Wi-Fi the interface is usually `en1`, and see the
Ethernet warning above.

---
---

# Part 2 — Create the three VMs

## 5. Start them one at a time

Three QEMU guests booting at once will each time out waiting for cloud-init. Wait for `Running`
before starting the next.

🖥️ **Mac mini**

```bash
limactl start --yes 1-lima/control-plane-01.yaml
```

🖥️ **Mac mini**

```bash
limactl start --yes 1-lima/worker-01.yaml
```

🖥️ **Mac mini**

```bash
limactl start --yes 1-lima/worker-02.yaml
```

The first start downloads the Ubuntu 26.04 cloud image — allow several minutes.

## 6. Verify the static addresses — this is the gate

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do printf '%-18s ' $n; limactl shell $n -- ip -4 -br addr show lima0 | awk '{print $3}'; done
```

Wants `10.218.65.21/24`, `.22/24`, `.23/24`. Anything else, fix it now — an address baked into a
cluster is painful to change later.

🖥️ **Mac mini** — the gateway must answer, or the nodes have no outbound network at all:

```bash
limactl shell control-plane-01 -- ping -c2 10.218.65.1
```

💻 **MacBook** — the check that actually matters, because it comes from a different machine:

```bash
ping -c2 10.218.65.21
```

If this fails while the address looks right inside the guest, your switch is dropping the guest's
MAC. No configuration inside the VM will fix that.

## 7. Set hostnames

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- sudo hostnamectl set-hostname $n; done
```

## 8. Prepare all three nodes

Swap off, kernel modules, sysctls, containerd with the systemd cgroup driver, then kubeadm. A few
minutes per node.

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl copy 1-lima/node-prep.sh $n:/tmp/node-prep.sh; done
```

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do echo "===== $n"; limactl shell $n -- sudo bash /tmp/node-prep.sh; done
```

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do printf '%-18s ' $n; limactl shell $n -- kubeadm version -o short; done
```

**All three must report the same version.**

---
---

# Part 3 — Build the cluster

## 9. Initialise the control plane

🖥️ **Mac mini**

```bash
limactl copy 2-cluster/kubeadm-config.yaml control-plane-01:/tmp/kubeadm-config.yaml
```

🖥️ **Mac mini**

```bash
limactl shell control-plane-01 -- sudo kubeadm init --config /tmp/kubeadm-config.yaml
```

A `NotReady` node and `Pending` CoreDNS straight after this is correct — there is no CNI yet.

## 10. Point kubectl at it

🖥️ **Mac mini**

```bash
mkdir -p ~/.kube && limactl shell control-plane-01 -- sudo cat /etc/kubernetes/admin.conf > ~/.kube/config-mini
```

🖥️ **Mac mini**

```bash
export KUBECONFIG=~/.kube/config-mini && kubectl get nodes
```

One node, `NotReady`. Every `kubectl` in Parts 3 and 4 runs on the mini with this set.

## 11. Install Calico

🖥️ **Mac mini**

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/tigera-operator.yaml
```

**`create`, not `apply`** — the CRDs exceed the annotation limit `apply` writes.

🖥️ **Mac mini** — Calico's dataplane must match the mode kube-proxy is running in, or two
subsystems write conflicting packet rules and nothing warns you. This reads kube-proxy's own
startup log and rewrites the manifest only if it disagrees:

```bash
kubectl -n kube-system logs -l k8s-app=kube-proxy | grep -qi 'nftables Proxier' && sed -i '' 's/linuxDataplane: Iptables/linuxDataplane: Nftables/' 2-cluster/calico-installation.yaml && echo "switched to Nftables" || echo "iptables Proxier — manifest already correct"
```

On Kubernetes v1.36 this reports iptables and changes nothing. Verify rather than assume; the
default has been widely misreported.

🖥️ **Mac mini**

```bash
kubectl apply -f 2-cluster/calico-installation.yaml
```

🖥️ **Mac mini**

```bash
kubectl -n calico-system get pods -w
```

🖥️ **Mac mini**

```bash
kubectl get nodes
```

`control-plane-01` is now `Ready`.

## 12. Join the workers

🖥️ **Mac mini** — mint a token and pull the two values straight out of it. Transcribing a 64-character
hash by hand is how this step usually goes wrong:

```bash
JOIN=$(limactl shell control-plane-01 -- sudo kubeadm token create --print-join-command) && export TOKEN=$(echo "$JOIN" | sed -n 's/.*--token \([^ ]*\).*/\1/p') HASH=$(echo "$JOIN" | sed -n 's/.*--discovery-token-ca-cert-hash sha256:\([^ ]*\).*/\1/p') && echo "TOKEN=$TOKEN" && echo "HASH=$HASH"
```

Both must print non-empty. A token expires after 24 hours — re-run this if you come back tomorrow.

🖥️ **Mac mini**

```bash
sed -e "s/<TOKEN>/$TOKEN/" -e "s/<HASH>/$HASH/" 2-cluster/join-worker-01.yaml > /tmp/join-worker-01.yaml && limactl copy /tmp/join-worker-01.yaml worker-01:/tmp/join.yaml
```

🖥️ **Mac mini**

```bash
sed -e "s/<TOKEN>/$TOKEN/" -e "s/<HASH>/$HASH/" 2-cluster/join-worker-02.yaml > /tmp/join-worker-02.yaml && limactl copy /tmp/join-worker-02.yaml worker-02:/tmp/join.yaml
```

🖥️ **Mac mini**

```bash
limactl shell worker-01 -- sudo kubeadm join --config /tmp/join.yaml
```

🖥️ **Mac mini**

```bash
limactl shell worker-02 -- sudo kubeadm join --config /tmp/join.yaml
```

🖥️ **Mac mini**

```bash
kubectl get nodes -o wide
```

All three `Ready`, and **check the `INTERNAL-IP` column**: it must read `.21`, `.22`, `.23`. A node
showing `192.168.5.15` joined over Lima's management network — that address is identical on every
node, so pod traffic to it will not work. Reset that node with
`limactl shell worker-01 -- sudo kubeadm reset -f` and re-join it.

## 13. MetalLB

🖥️ **Mac mini**

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
```

🖥️ **Mac mini** — **wait for these.** The pool is validated by a webhook MetalLB serves itself:

```bash
kubectl -n metallb-system wait --for=condition=available deploy/controller --timeout=180s
kubectl -n metallb-system wait --for=condition=ready pod -l component=speaker --timeout=180s
```

🖥️ **Mac mini**

```bash
kubectl apply -f 2-cluster/metallb-pool.yaml
```

## 14. Gateway API CRDs

🖥️ **Mac mini**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```

## 15. cert-manager and the private CA

🖥️ **Mac mini**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml
```

🖥️ **Mac mini** — **wait for this too**, same webhook problem:

```bash
kubectl -n cert-manager wait --for=condition=available deploy --all --timeout=180s
```

🖥️ **Mac mini**

```bash
kubectl apply -f 2-cluster/cert-manager-ca.yaml
```

🖥️ **Mac mini**

```bash
kubectl get clusterissuer
```

Both `READY: True`.

🖥️ **Mac mini**

```bash
kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f - && kubectl apply -f 2-cluster/cert-manager-gateway-cert.yaml
```

🖥️ **Mac mini**

```bash
kubectl -n traefik get certificate gateway-tls
```

`READY: True`. cert-manager creates the Secret itself and renews it automatically.

## 16. Traefik

🖥️ **Mac mini**

```bash
kubectl apply -f 2-cluster/traefik/
```

🖥️ **Mac mini**

```bash
kubectl -n traefik get svc traefik
```

`EXTERNAL-IP` must show `10.218.65.27`.

🖥️ **Mac mini**

```bash
kubectl -n traefik get gateway traefik-gateway
```

`PROGRAMMED: True`.

## 17. Prove it from outside

💻 **MacBook** — this is the check that matters, because it comes from a different machine:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -k https://10.218.65.27/
```

**`404` is success.** Traefik is answering and no route matches yet. A timeout means the L2
announcement is not reaching you.

## 18. Export the CA and trust it on the Mac mini

🖥️ **Mac mini**

```bash
kubectl -n cert-manager get secret cluster-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

🖥️ **Mac mini**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cluster-ca.crt
```

🖥️ **Mac mini**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://10.218.65.27/
```

`404`, now with no `-k`. One import covers every certificate the cluster will ever issue.

**Keep `cluster-ca.crt`.** Step 21 pushes it into the three nodes. The MacBook fetches its own
copy in step 23, so this file never has to be transferred. It is gitignored.

---
---

# Part 4 — Cluster add-ons

Three things a bare `kubeadm` cluster lacks: dynamic storage, a metrics pipeline, and a reachable
image registry. All of Part 4 runs on the mini.

## 19. A default StorageClass

🖥️ **Mac mini**

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
```

🖥️ **Mac mini** — the manifest does not mark itself default, and claims that omit
`storageClassName` will not bind without this:

```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## 20. metrics-server

🖥️ **Mac mini**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
```

🖥️ **Mac mini** — it will not go ready until this patch. kubeadm gives each kubelet a self-signed
serving certificate, which metrics-server refuses to trust:

```bash
kubectl -n kube-system patch deploy metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

🖥️ **Mac mini**

```bash
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s && kubectl top nodes
```

Real numbers.

## 21. The registry, and teaching the nodes to trust it

🖥️ **Mac mini**

```bash
kubectl apply -f 2-cluster/registry.yaml
```

🖥️ **Mac mini**

```bash
curl -sSk https://registry.10-218-65-27.traefik.me/v2/_catalog
```

`{"repositories":[]}` exercises DNS, the address, the L2 announcement, Traefik, TLS and the
registry in one request. **Get this green before continuing** — every image push depends on it.

Now the nodes, because containerd is what pulls the images.

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl copy cluster-ca.crt $n:/tmp/cluster-ca.crt; done
```

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl shell $n -- sudo mkdir -p /etc/containerd/certs.d/registry.10-218-65-27.traefik.me && limactl shell $n -- sudo cp /tmp/cluster-ca.crt /etc/containerd/certs.d/registry.10-218-65-27.traefik.me/ca.crt && echo "$n done"; done
```

No restart is needed — containerd reads that directory on every pull.

**The Mac mini's part is done here.** Everything below happens on the MacBook.

---
---

# Part 5 — Build and deploy, from the MacBook

## 22. Point kubectl at the cluster

The kubeconfig is the one file that has to physically move between the machines. Everything else
the MacBook needs, it pulls from the cluster itself once this works.

💻 **MacBook** — the mini is at a static `10.218.65.20` and the owning account is `ladmin`:

```bash
export MINI=10.218.65.20 MINI_USER=ladmin
```

`ladmin` is the account's **short name**, which is what SSH wants — not the display name System
Settings shows. If the copy below is refused, confirm it by running `whoami` on the mini while
logged into that account, and use whatever it prints.

💻 **MacBook** — copy the kubeconfig across. You will be asked for `ladmin`'s password:

```bash
mkdir -p ~/.kube && scp "$MINI_USER@$MINI:.kube/config-mini" ~/.kube/config-mini && chmod 600 ~/.kube/config-mini
```

The API server certificate already covers `10.218.65.21`, so the file works unmodified.

💻 **MacBook** — set the three variables this part uses, from inside your `mac-mini/` clone:

```bash
export REPO="$(pwd)" SRC="$(cd .. && pwd)" KUBECONFIG=~/.kube/config-mini && ls "$SRC"
```

Wants `mac-mini`, `planpal-backend-learner7-ch4` and `planpal-frontend-learner7-ch4`.

💻 **MacBook**

```bash
kubectl get nodes
```

Three nodes, all `Ready`. That kubeconfig embeds an administrator credential — treat it as a
password, and note `chmod 600` above is not decoration.

## 23. Trust the CA — for the browser and for `docker push`

`kubectl` works now, so the MacBook fetches the CA itself rather than copying a second file.

💻 **MacBook**

```bash
kubectl -n cert-manager get secret cluster-ca-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

💻 **MacBook** — trust it system-wide, which covers `curl` and the browser:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cluster-ca.crt
```

**Docker does not read the macOS keychain.** It needs its own copy, at a path the daemon inside
the VM can see:

💻 **MacBook**

```bash
mkdir -p ~/.docker/certs.d/registry.10-218-65-27.traefik.me && cp cluster-ca.crt ~/.docker/certs.d/registry.10-218-65-27.traefik.me/ca.crt
```

**Not `/etc/docker/certs.d`.** That is the path on a Linux host. On macOS the daemon runs inside a
VM and reads `~/.docker/certs.d` instead — a directory created under `/etc` on the Mac is never
looked at, and `docker push` fails with `x509: certificate signed by unknown authority`.

💻 **MacBook** — confirm what the daemon actually sees, rather than trusting either path. This
prints the VM's own view of the directory, so it is correct on OrbStack and Docker Desktop alike:

```bash
docker run --rm -v /etc/docker/certs.d:/c alpine ls -la /c
```

`registry.10-218-65-27.traefik.me` must appear in that listing.

💻 **MacBook**

```bash
curl -sS --cacert cluster-ca.crt https://registry.10-218-65-27.traefik.me/v2/_catalog
```

`{"repositories":[]}` means the chain verifies.

## 24. Build and push the twelve images

Tag each image with the registry hostname **at build time** — a Docker image's name *is* its push
destination, so there is no separate upload step to get wrong.

💻 **MacBook** — six HTTP services:

```bash
cd "$SRC/planpal-backend-learner7-ch4" && for s in auth meeting calendar notification ai slack; do docker build --target service-http --build-arg BIN=planpal-$s-server -t registry.10-218-65-27.traefik.me/planpal-$s-server:dev . ; done
```

💻 **MacBook** — four workers:

```bash
for s in meeting calendar notification ai; do docker build --target service-worker --build-arg BIN=planpal-$s-worker -t registry.10-218-65-27.traefik.me/planpal-$s-worker:dev . ; done
```

💻 **MacBook** — the migration image:

```bash
docker build --target migrate -t registry.10-218-65-27.traefik.me/planpal-migrate:dev .
```

Eleven builds, but one Rust compile — they share a builder stage, so only the first is slow.

💻 **MacBook** — the frontend, which is the one most easily got wrong:

```bash
cd "$SRC" && docker build --build-arg NEXT_PUBLIC_API_URL=https://planpal-api.10-218-65-27.traefik.me/api/v1 -t registry.10-218-65-27.traefik.me/planpal-web:dev ./planpal-frontend-learner7-ch4
```

Next.js bakes `NEXT_PUBLIC_*` into the bundle at **build** time. A ConfigMap cannot change it
later. The eleven Rust images read every hostname from the ConfigMap at startup instead.

💻 **MacBook**

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^registry.10-218-65-27.traefik.me/' | xargs -n1 docker push
```

💻 **MacBook**

```bash
curl -sS --cacert "$REPO/cluster-ca.crt" https://registry.10-218-65-27.traefik.me/v2/_catalog
```

Twelve repositories. If a push fails partway with a timeout rather than a TLS error, that is
Traefik's `readTimeout` — see the guide.

💻 **MacBook**

```bash
cd "$REPO"
```

## 25. Render the Secret

`make-secrets.sh` reads the two `.env` files from the sibling repos and writes
`3-app/05-secrets.yaml` (mode 600, gitignored). It prints key *names* only, never values.

💻 **MacBook**

```bash
bash 3-app/make-secrets.sh
```

It exits non-zero on a missing required key, and lists any value still shaped like a placeholder.

`3-app/secrets.example.yaml.tpl` is the committed reference for every key and what it is for.

## 26. Deploy

💻 **MacBook**

```bash
kubectl apply -f 3-app/
```

The filenames are numbered because `kubectl` applies a directory in filename order, and that
ordering is the only reason a single apply works.

💻 **MacBook**

```bash
kubectl -n planpal wait --for=condition=complete job/planpal-migrate --timeout=300s
```

**`CrashLoopBackOff` for the first minute is expected.** Postgres, NATS and Redis are hard startup
dependencies; whichever service starts first exits and restarts until they answer. No intervention
needed.

💻 **MacBook**

```bash
kubectl -n planpal get pods -w
```

---
---

# Check it works

💻 **MacBook**

```bash
kubectl -n planpal get pods -o wide
```

Everything `Running`, and `auth-server` on two different nodes — that is the spread constraint
working.

💻 **MacBook**

```bash
curl -sS https://planpal-api.10-218-65-27.traefik.me/api/v1/health
```

💻 **MacBook**

```bash
kubectl -n planpal exec sts/nats -- wget -qO- 'http://127.0.0.1:8222/jsz?streams=1' | grep -E '"streams"|"consumers"'
```

Wants `streams: 1` and `consumers: 8`.

💻 **MacBook**

```bash
kubectl -n planpal get pvc && kubectl -n planpal get hpa
```

Two `Bound` claims, and a real percentage under HPA `TARGETS` — `<unknown>` means metrics-server
is not serving.

💻 **MacBook** — finally, open **https://planpal.10-218-65-27.traefik.me** in a browser. No
certificate warning, if you did step 23.

---

# Day to day

**Ship a code change.** `:dev` is a mutable tag, so a rebuild updates only the local image — the
push is what the cluster sees.

💻 **MacBook** — rebuild and push the one service you changed:

```bash
cd "$SRC/planpal-backend-learner7-ch4" && docker build --target service-http --build-arg BIN=planpal-auth-server -t registry.10-218-65-27.traefik.me/planpal-auth-server:dev . && docker push registry.10-218-65-27.traefik.me/planpal-auth-server:dev
```

💻 **MacBook**

```bash
cd "$REPO" && kubectl -n planpal rollout restart deploy/auth-server
```

Manifests set `imagePullPolicy: Always`, so the restart picks up the new push.

**Change a hostname or the API URL.** Rebuild and push `planpal-web` — the frontend has it baked
in. The Rust services only need a `rollout restart`.

**Rotate a credential.** 💻 On the MacBook: edit the `.env`, re-run `make-secrets.sh`,
`kubectl apply -f 3-app/`, then `rollout restart` the affected workloads. Note `POSTGRES_PASSWORD`
is read **only when the data directory is empty** — changing it on a running database does nothing
without an `ALTER ROLE`.

**Free up the mini.** Stopping is safe; the static addresses live in the guest filesystem and come
back on their own.

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl stop $n; done
```

🖥️ **Mac mini**

```bash
for n in control-plane-01 worker-01 worker-02; do limactl start $n; done
```

---

# When something breaks

[docs/BUILD-GUIDE.md](docs/BUILD-GUIDE.md) ends with a troubleshooting table indexed by symptom,
split by part. A few that come up most:

| Symptom | Where | Cause |
|---|---|---|
| `EXTERNAL-IP` stuck `<pending>` | mini | MetalLB pool not applied, or applied before its webhook was ready |
| Node `INTERNAL-IP` is `192.168.5.15` | mini | Joined over Lima's management network. Reset and re-join that node |
| Pods run, Services never connect | mini | `br_netfilter` not loaded — re-run `node-prep.sh` on that node |
| `docker push`: `x509: certificate signed by unknown authority` | MacBook | CA missing from `~/.docker/certs.d/<host>/ca.crt`, or put under `/etc` by mistake |
| `docker push` uploads then fails partway | MacBook | Traefik `readTimeout` is not 0 |
| Pod `ErrImagePull` with an x509 error | mini | CA missing from `/etc/containerd/certs.d/<host>/ca.crt` on that node |
| Rebuilt an image, cluster runs the old code | MacBook | Rebuild updates the local image only. Push again |
| Frontend calls the wrong API host | MacBook | Web image built with a stale `NEXT_PUBLIC_API_URL`. Rebuild and push |
| HPA `TARGETS` stuck at `<unknown>` | mini | metrics-server not serving, or a container has no CPU request |
| All pods `Running`, nothing gets processed | either | JetStream stream lost. `kubectl -n planpal rollout restart deploy` |
| `make-secrets.sh`: missing env file | MacBook | The three repos are not siblings. Check `ls "$SRC"` |
| `scp`: `Permission denied` or connection refused | MacBook | Remote Login off on the mini, or `ladmin` is not the account's short name. Run `whoami` on the mini to confirm |
| `limactl list` empty, but the cluster still answers | mini | Logged in as someone other than `ladmin`. Lima keeps the VMs in that account's `~/.lima` |

The full teardown procedure — four levels, least to most destructive — is at the end of the guide.

---

# What is in this repo

| Path | Contents |
|---|---|
| `1-lima/` | Three VM definitions and `node-prep.sh`, which runs inside each guest |
| `2-cluster/` | kubeadm config, join files, Calico, MetalLB, cert-manager, Traefik, the registry |
| `3-app/` | PlanPal — 23 numbered manifests, plus `make-secrets.sh` and the secrets reference |
| `docs/BUILD-GUIDE.md` | The full build with every decision explained, and the troubleshooting index |

Versions are pinned deliberately: Kubernetes v1.36.0, Ubuntu 26.04, Calico v3.31.0, MetalLB
v0.16.1, Gateway API v1.5.1, cert-manager v1.21.1, Traefik v3.7.10, metrics-server v0.8.0,
local-path-provisioner v0.0.37.
