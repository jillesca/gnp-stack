# GNP-Stack Deployment

## Deployment Modes

### 1. Full VM mode (everything on one host)

All containers run on the VM. Alloy connects to XRd devices via macvlan.

```bash
make up-vm
```

Requires the `segment-routing_mgmt` macvlan network to exist on the Docker host.

---

### 2. Full laptop mode (local dev, no syslog)

All containers run on the laptop. No Alloy/syslog ingestion.

```bash
make up
```

---

### 3. Split mode — recommended when VM RAM is limited

Alloy + Loki run on the **VM** (close to XRd devices, connected via macvlan).
Grafana + Prometheus + NATS + gnmic run on the **laptop**.
Grafana queries Loki remotely over the VPN.

```text
VM (XRd host)                     Laptop
─────────────────────────         ─────────────────────────
XRd (×N)  ← containerlab         Grafana  →  Loki @ VM:3100
Alloy     ← syslog from XRd      Prometheus
Loki      ← Alloy push           NATS + gnmic
port 3100 exposed                (no Loki container)
```

#### Prerequisites

- SSH key auth from laptop to VM (no password prompts)
- `segment-routing_mgmt` macvlan network on VM
- Port 3100 reachable from laptop to VM (VPN/lab network)

#### Step 1 — Deploy Alloy + Loki to the VM

```bash
# Defaults: VM_HOST=10.10.20.15  VM_USER=developer  VM_PATH=/home/developer/gnp-syslog
make vm-deploy

# Override any default:
make vm-deploy VM_HOST=10.10.20.15 VM_USER=developer
```

This rsync's `alloy/`, `loki/`, and `vm/` to the VM, then starts the containers via SSH.

#### Step 2 — Start the laptop stack pointing at remote Loki

```bash
LOKI_URL=http://10.10.20.15:3100 make up
```

Or add it to a `.env` file in the project root (never commit this file):

```bash
echo "LOKI_URL=http://10.10.20.15:3100" >> .env
make up
```

#### Step 3 — Configure XRd syslog destination

Run the ansible playbook (defaults to Alloy's macvlan IP `10.10.20.11`):

```bash
cd ansible-helper
ansible-playbook -i hosts xrd_apply_config.yaml
```

To override the syslog destination (e.g., for laptop mode testing):

```bash
SYSLOG_DESTINATION=192.168.254.11 ansible-playbook -i hosts xrd_apply_config.yaml
# or
ansible-playbook -i hosts xrd_apply_config.yaml -e syslog_destination=192.168.254.11
```

#### Split mode management

```bash
make vm-status   # show containers on VM
make vm-logs     # follow Alloy+Loki logs on VM
make vm-stop     # stop VM syslog stack
make vm-start    # start VM syslog stack (after vm-sync)
```

---

## Configuration Reference

| Env var              | Default                      | Description                          |
| -------------------- | ---------------------------- | ------------------------------------ |
| `VM_HOST`            | `10.10.20.15`                | VM IP/hostname for SSH and rsync     |
| `VM_USER`            | `developer`                  | SSH user on the VM                   |
| `VM_PATH`            | `/home/developer/gnp-syslog` | Remote working directory             |
| `LOKI_URL`           | `http://loki:3100`           | Loki URL used by Grafana datasource  |
| `SYSLOG_DESTINATION` | `10.10.20.11`                | IP XRd devices send syslog to        |
| `SYSLOG_PORT`        | `5514`                       | Syslog listener port                 |
| `ALLOY_MACVLAN_IP`   | `10.10.20.11`                | Alloy's static IP on the XRd macvlan |

---

## Kubernetes Deployment

For Kubernetes deployment, refer to [install/kubernetes/gnp-stack/README.md](install/kubernetes/gnp-stack/README.md).
