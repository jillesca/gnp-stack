# XRd Segment Routing Telemetry Design

## Purpose

This document is an implementation guide for AI agents. It describes all architectural decisions, file changes, acceptance criteria, and constraints needed to extend the gnp-stack project to support Cisco XRd devices running a Segment Routing topology, add Grafana Loki for log correlation, configure alerting, and integrate with an AI-driven network investigation system.

**Do not ask the author for clarification before starting a phase. Every decision is recorded here. If you encounter a constraint not covered, document it in a `BLOCKERS.md` file at the repo root and stop.**

---

## Context and Existing Projects

| Project           | Repo                                                                              | Role                                                                                     |
| ----------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| gnp-stack         | this repo                                                                         | Telemetry stack: gNMIc + NATS + Prometheus + Grafana                                     |
| gNMIBuddy         | <https://github.com/jillesca/gNMIBuddy>                                           | MCP tool: pulls structured data from XRd via gNMI                                        |
| sp_oncall         | <https://github.com/jillesca/sp_oncall>                                           | LangGraph multi-agent graph: investigates network issues                                 |
| XRd Sandbox       | <https://github.com/CiscoDevNet/XRd-Sandbox/tree/main/topologies/segment-routing> | XRd topology, configs, and sandbox setup                                                 |
| Previous TIG demo | <https://github.com/jillesca/oncall-netops-tig-pyats-demo>                        | Prior art: TIG stack + ISIS alert → LangGraph (different topology, do not port directly) |

---

## XRd Topology

Eight XRd Control Plane routers running IOS-XR 25.3.1, deployed via Docker on a Cisco DevNet sandbox VM (`10.10.20.15`). The topology is a Segment Routing MPLS network.

```
                 xrd-7 (PCE)
               /             \
           xrd-3 --------- xrd-4
           / |                 | \
src -- xrd-1  |                 |  xrd-2 -- dst
           \ |                 | /
           xrd-5 --------- xrd-6
               \             /
                xrd-8 (vRR)
```

| Device | Role      | Management IP | gNMI Port |
| ------ | --------- | ------------- | --------- |
| xrd-1  | PE / Edge | 10.10.20.101  | 57777     |
| xrd-2  | PE / Edge | 10.10.20.102  | 57777     |
| xrd-3  | P / Core  | 10.10.20.103  | 57777     |
| xrd-4  | P / Core  | 10.10.20.104  | 57777     |
| xrd-5  | P / Core  | 10.10.20.105  | 57777     |
| xrd-6  | P / Core  | 10.10.20.106  | 57777     |
| xrd-7  | PCE       | 10.10.20.107  | 57777     |
| xrd-8  | vRR       | 10.10.20.108  | 57777     |

Credentials: `cisco` / `C1sco12345`. gNMI is insecure (no TLS).

XRd uses Docker macvlan networking (`ens160`, subnet `10.10.20.0/24`, gateway `10.10.20.254`). XRd containers can reach external networks and other Docker containers on the same host. They **cannot** reach the VM host IP `10.10.20.15` directly (macvlan host isolation).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Sandbox VM (10.10.20.15)  —  runs gnp-stack + XRd      │
│                                                          │
│  ┌──────────┐  gNMI (57777)   ┌─────────────────────┐  │
│  │  XRd 1-8 │ ──────────────> │  gnmic-ingestor      │  │
│  │ 10.10.20 │                 │  (OpenConfig + XR    │  │
│  │ .101-108 │  syslog UDP     │   native YANG paths) │  │
│  │          │ ──────────────> │  gnmic-emitter       │  │
│  └──────────┘                 └──────────┬──────────-─┘  │
│                                          │ NATS JetStream│
│                               ┌──────────▼────────────┐  │
│                               │  NATS (stream: xrd)   │  │
│                               └──────────┬────────────┘  │
│                                          │               │
│                               ┌──────────▼────────────┐  │
│                               │  Prometheus            │  │
│                               │  (remote write)        │  │
│                               └──────────┬────────────┘  │
│                                          │               │
│  ┌──────────────────────────────────────▼────────────┐  │
│  │  Grafana (port 3000)                               │  │
│  │  - Prometheus datasource (metrics)                 │  │
│  │  - Loki datasource (logs)                          │  │
│  │  - Dashboard: xrd-sr-overview                      │  │
│  │  - Alert rules → webhook contact point             │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────┐   syslog UDP    ┌────────────────┐  │
│  │  XRd devices   │ ─────────────>  │  Grafana Alloy │  │
│  └────────────────┘                 │  (syslog recv) │  │
│                                     └───────┬────────┘  │
│                                             │ push       │
│                                     ┌───────▼────────┐  │
│                                     │  Loki          │  │
│                                     └────────────────┘  │
└─────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  Laptop (user's macOS)                                   │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  sp_oncall (LangGraph + gNMIBuddy MCP)             │  │
│  │  - Receives webhook alert                           │  │
│  │  - Agents investigate devices via gNMIBuddy         │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │ webhook POST                   │
│                         │                               │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │  Webhook Receiver (FastAPI)  [Phase 4]             │  │
│  │  - Translates Grafana payload → alert schema        │  │
│  │  - Kicks off LangGraph thread                       │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

| Decision                    | Choice                                                                         | Rationale                                                                        |
| --------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Where gnp-stack runs        | Sandbox VM (Docker)                                                            | XRd cannot push syslog to laptop; VM containers can reach XRd via Docker routing |
| Container engine            | Docker on VM, Podman on laptop; Makefile detects                               | Author uses both environments                                                    |
| Log ingestion               | Grafana Alloy (syslog receiver) → Loki                                         | Real-time, native Grafana stack, push-based                                      |
| Log collection method       | XRd pushes syslog to Alloy (UDP)                                               | Pull-based gNMI log polling is not real-time enough for alert correlation        |
| gNMI path model             | OpenConfig primary + XR native YANG for richer metrics                         | OpenConfig confirmed working on XRd 25.3.1 via gNMIBuddy                         |
| Alert scenario (primary)    | Interface down → ISIS adjacency cascade                                        | Most compelling demo: one event, visible cascade, agents find root cause         |
| Alert scenarios (secondary) | BGP session down, SR-TE path failure, vRR peer loss                            | Implement if time allows; alert payload schema supports all                      |
| Alert payload               | Minimal, generic schema (no node_role hardcoding)                              | gNMIBuddy MCP determines device role dynamically; keeps payload extensible       |
| Dashboards                  | New XRd dashboards in `grafana/dashboards/xrd/`; existing dashboards untouched | Preserves upstream gnp-stack dashboards; isolates XRd contribution               |
| Dashboard layout            | Single-pane-of-glass, all rows expanded                                        | Demo audience sees one screen; no navigation needed                              |
| Webhook receiver            | FastAPI (Phase 4, built last)                                                  | Lowest risk; dashboards and alerting proven before integration                   |
| Future NSO integration      | Out of scope for this document                                                 | Author may add NSO + MCP for intended-state comparison after Cisco Live          |

---

## Networking Constraint: Syslog Routing

XRd devices live on macvlan network `10.10.20.0/24`. Grafana Alloy runs as a container on the gnp-stack Docker bridge `192.168.60.0/24`.

**Problem**: XRd cannot reach the VM host IP (`10.10.20.15`) due to macvlan host isolation.

**Solution**: Expose Alloy's syslog port on all interfaces via Docker port binding (`0.0.0.0:5514:5514/udp`). Docker's iptables FORWARD rules allow XRd to route to the gnp-stack bridge network through the VM's routing stack. XRd sends syslog to the gnp-stack bridge gateway IP.

**Validation the implementing agent must run on the VM before configuring XRd syslog:**

```bash
# Find the gnp-stack bridge gateway IP (this is what XRd sends syslog to)
docker network inspect gnp-stack_gnp-mgmt | grep Gateway

# Verify routing from a container on the gnp-stack network to an XRd device
docker run --rm --network gnp-stack_gnp-mgmt alpine ping -c 3 10.10.20.101

# From an XRd device, verify it can reach the Alloy syslog port
# SSH to xrd-1 and run: ping 192.168.60.1 (or whatever gateway IP was found above)
```

If routing does not work, alternative: use `network_mode: host` for the Alloy container and bind to `0.0.0.0:5514`. XRd sends to any reachable IP on the VM. The gnp-stack container network uses port `5514` (>1024, no root needed).

---

## Phase 1: Foundation

**Goal**: Replace SRL-specific subscriptions with XRd-compatible paths. Validate data flows end-to-end into Prometheus. Add Makefile for container engine portability.

**Done when**: `make up` works on both laptop (Podman) and VM (Docker). Prometheus at `:9090` shows XRd metrics with labels `target=xrd-1` through `target=xrd-8`.

### 1.1 Makefile

Create `Makefile` at the repo root. Auto-detect container engine:

```makefile
CONTAINER_ENGINE := $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE          := $(CONTAINER_ENGINE) compose

.PHONY: up down restart logs ps validate

up:
 $(COMPOSE) up -d

down:
 $(COMPOSE) down

restart: down up

logs:
 $(COMPOSE) logs -f

ps:
 $(COMPOSE) ps

validate:
 @echo "Container engine: $(CONTAINER_ENGINE)"
 @echo "Checking Prometheus metrics..."
 @curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'
```

### 1.2 `gnmic/gnmic-ingestor.yaml` — XRd subscriptions

Replace the existing SRL-named subscriptions with XRd OpenConfig subscriptions. Keep the EOS subscriptions as-is (they are not used for XRd but preserve upstream compatibility).

**Target block**: Remove all existing targets. Add:

```yaml
targets:
  10.10.20.101:
    name: xrd-1
    subscriptions:
      - xrd-if-states
      - xrd-if-stats
      - xrd-isis-adjacency
      - xrd-isis-stats
      - xrd-bgp-sessions
      - xrd-bgp-stats
      - xrd-mpls-labels
      - xrd-system-health
  10.10.20.102:
    name: xrd-2
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
  10.10.20.103:
    name: xrd-3
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
  10.10.20.104:
    name: xrd-4
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
  10.10.20.105:
    name: xrd-5
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
  10.10.20.106:
    name: xrd-6
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
  10.10.20.107:
    name: xrd-7
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
        xrd-pce-topology,
      ]
  10.10.20.108:
    name: xrd-8
    subscriptions:
      [
        xrd-if-states,
        xrd-if-stats,
        xrd-isis-adjacency,
        xrd-isis-stats,
        xrd-bgp-sessions,
        xrd-bgp-stats,
        xrd-mpls-labels,
        xrd-system-health,
      ]
```

> Note: `xrd-pce-topology` is only assigned to xrd-7 (PCE).

**Subscription block**: Add the following subscriptions. Keep existing SRL/EOS subscriptions below them for upstream compatibility.

```yaml
subscriptions:
  # ── XRd / IOS-XR 25.3.1 ─────────────────────────────────────────────────

  # Interface operational state (on_change for immediate alert triggering)
  xrd-if-states:
    mode: stream
    stream-mode: on_change
    heartbeat-interval: 30s
    paths:
      - /interfaces/interface[name=*]/state/oper-status
      - /interfaces/interface[name=*]/state/admin-status
    outputs:
      - nats-xrd-out

  # Interface traffic statistics (sampled)
  xrd-if-stats:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - /interfaces/interface[name=*]/state/counters
    outputs:
      - nats-xrd-out

  # ISIS adjacency state (on_change for immediate alert triggering)
  xrd-isis-adjacency:
    mode: stream
    stream-mode: on_change
    heartbeat-interval: 30s
    paths:
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/interfaces/interface[name=*]/levels/level[level-number=*]/adjacencies/adjacency/adjacency-state
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/interfaces/interface[name=*]/levels/level[level-number=*]/adjacencies/adjacency/neighbor-ipv4-address
    outputs:
      - nats-xrd-out

  # ISIS global counters (SPF runs, LSP counts)
  xrd-isis-stats:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/global/counters
    outputs:
      - nats-xrd-out

  # BGP session state (on_change)
  xrd-bgp-sessions:
    mode: stream
    stream-mode: on_change
    heartbeat-interval: 30s
    paths:
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/session-state
    outputs:
      - nats-xrd-out

  # BGP message counters (sampled)
  xrd-bgp-stats:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/messages
      - /network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/prefixes
    outputs:
      - nats-xrd-out

  # MPLS label usage — XR native YANG (richer than OpenConfig for SR)
  xrd-mpls-labels:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - Cisco-IOS-XR-mpls-lsd-oper:mpls-lsd/label-summary
    outputs:
      - nats-xrd-out

  # System health — XR native YANG
  xrd-system-health:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - Cisco-IOS-XR-wdsysmon-fd-oper:system-monitoring/cpu-utilization
      - Cisco-IOS-XR-nto-misc-oper:memory-summary/nodes/node/summary
    outputs:
      - nats-xrd-out

  # PCE topology — XR native YANG (xrd-7 only)
  xrd-pce-topology:
    mode: stream
    stream-mode: sample
    sample-interval: 30s
    paths:
      - Cisco-IOS-XR-infra-xtc-oper:pce/topology-summary
    outputs:
      - nats-xrd-out
```

**Output block**: Add alongside existing outputs:

```yaml
nats-xrd-out:
  type: jetstream
  name: gnmic-ingress-xrd
  address: nats:4222
  stream: xrd
  create-stream:
    retention-policy: workqueue
```

### 1.3 `gnmic/gnmic-emitter.yaml` — XRd stream input

Add a new input for the XRd NATS stream alongside the existing `nats-srl` and `nats-eos` inputs:

```yaml
nats-xrd:
  type: jetstream
  name: gnmic-xrd-emitter
  address: nats:4222
  stream: xrd
  subjects: []
  format: event
  deliver-policy: all
  subject-format: subscription.target
  connect-time-wait: 3s
  debug: false
  num-workers: 1
  buffer-size: 1000
  fetch-batch-size: 500
  max-ack-pending: 100000
  outputs:
    - prom-write
  event-processors:
    - xrd-state-to-int
```

Add the XRd state-to-integer processor alongside existing processors:

```yaml
# XRd: OpenConfig interface and protocol state values → integers for Prometheus
xrd-state-to-int:
  event-strings:
    value-names:
      - "oper-status"
      - "admin-status"
      - "adjacency-state"
      - "session-state"
    transforms:
      # Interface states
      - replace:
          apply-on: "value"
          old: "UP"
          new: "1"
      - replace:
          apply-on: "value"
          old: "DOWN"
          new: "0"
      - replace:
          apply-on: "value"
          old: "LOWER_LAYER_DOWN"
          new: "0"
      # ISIS adjacency states
      - replace:
          apply-on: "value"
          old: "INIT"
          new: "2"
      - replace:
          apply-on: "value"
          old: "FAILED"
          new: "0"
      # BGP session states
      - replace:
          apply-on: "value"
          old: "ESTABLISHED"
          new: "1"
      - replace:
          apply-on: "value"
          old: "IDLE"
          new: "0"
      - replace:
          apply-on: "value"
          old: "ACTIVE"
          new: "0"
      - replace:
          apply-on: "value"
          old: "CONNECT"
          new: "0"
      - replace:
          apply-on: "value"
          old: "OPENSENT"
          new: "0"
      - replace:
          apply-on: "value"
          old: "OPENCONFIRM"
          new: "0"
```

### 1.4 Validation — Phase 1

After `make up` on the VM:

1. Check gnmic-ingestor logs for subscription errors:

   ```bash
   docker compose logs gnmic-ingestor | grep -E "ERROR|failed|subscribe"
   ```

2. Verify XRd metrics appear in Prometheus:

   ```bash
   # Should return results for each device
   curl -s 'http://localhost:9090/api/v1/query?query=up{job="gnmic"}' | python3 -m json.tool
   ```

3. Query an interface state metric:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=interfaces_interface_state_oper_status' | python3 -m json.tool
   ```

4. If any XR native YANG path returns no data (subscription error in logs), remove that path and add a comment noting it is unsupported on this XRd version. OpenConfig paths are the fallback.

---

## Phase 2: Rich Telemetry + Loki + Dashboards

**Goal**: Add Loki for log ingestion. Add Grafana Alloy as syslog receiver. Build the XRd single-pane-of-glass dashboard. Configure XRd devices to push syslog.

**Done when**: Grafana at `:3000` shows the `xrd-sr-overview` dashboard with live metrics from all 8 devices AND syslog lines from XRd appear in the Loki log panel.

### 2.1 `compose.yaml` — Add Loki and Alloy

Add the following services to `compose.yaml`:

```yaml
loki:
  image: grafana/loki:3.5.0
  ports:
    - 3100:3100
  command: -config.file=/etc/loki/loki-config.yaml
  volumes:
    - ./loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro
  networks:
    - gnp-mgmt

alloy:
  image: grafana/alloy:v1.8.3
  ports:
    - 5514:5514/udp # XRd syslog receiver (UDP)
    - 5514:5514/tcp # XRd syslog receiver (TCP fallback)
    - 12345:12345 # Alloy UI (optional, for debugging)
  volumes:
    - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
  command: run /etc/alloy/config.alloy
  networks:
    - gnp-mgmt
  depends_on:
    - loki
```

Also update the `grafana` service to depend on `loki`:

```yaml
grafana:
  depends_on:
    - loki # add to existing depends_on if any
```

### 2.2 `loki/loki-config.yaml` — New file

Create directory `loki/` and file `loki/loki-config.yaml`:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /tmp/loki
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  reject_old_samples: false
  reject_old_samples_max_age: 168h
```

### 2.3 `alloy/config.alloy` — New file

Create directory `alloy/` and file `alloy/config.alloy`:

```alloy
// Grafana Alloy configuration for XRd syslog ingestion

loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}

loki.source.syslog "xrd_syslog" {
  listener {
    address  = "0.0.0.0:5514"
    protocol = "udp"
    labels = {
      job    = "xrd-syslog",
      source = "xrd",
    }
  }
  listener {
    address  = "0.0.0.0:5514"
    protocol = "tcp"
    labels = {
      job    = "xrd-syslog",
      source = "xrd",
    }
  }
  forward_to          = [loki.write.default.receiver]
  use_rfc5424_message = true
}
```

> **Networking note**: After `make up`, run the validation commands from the Networking Constraint section above to confirm XRd can route to the Alloy container's port 5514. The bridge gateway IP found from `docker network inspect gnp-stack_gnp-mgmt` is the syslog destination for XRd.

### 2.4 XRd syslog configuration

Apply to all 8 XRd devices. Replace `<ALLOY_GATEWAY_IP>` with the bridge gateway IP found during validation (typically `192.168.60.1`).

IOS-XR syslog config (add to each device's running config or startup config):

```
logging <ALLOY_GATEWAY_IP> vrf default severity warnings port 5514
logging source-interface MgmtEth0/RP0/CPU0/0
```

Apply via Ansible or manually via SSH. To apply via SSH:

```bash
ssh cisco@10.10.20.101 "conf t
logging <ALLOY_GATEWAY_IP> vrf default severity warnings port 5514
logging source-interface MgmtEth0/RP0/CPU0/0
commit
end"
```

Repeat for IPs `10.10.20.102` through `10.10.20.108`.

### 2.5 `grafana/provisioning/datasource.yaml` — Add Loki

Append the Loki datasource to the existing `datasource.yaml`:

```yaml
- name: Loki
  type: loki
  orgId: 1
  url: http://loki:3100
  basicAuth: false
  isDefault: false
  version: 1
  editable: true
```

### 2.6 `grafana/provisioning/dashboards.yaml` — Add XRd folder

Append a second provider for the XRd dashboards:

```yaml
- name: XRd
  folder: XRd SR Topology
  type: file
  options:
    path: /var/lib/grafana/dashboards/xrd
```

Also mount the new folder in `compose.yaml` by ensuring the Grafana volumes include:

```yaml
- ./grafana/dashboards/:/var/lib/grafana/dashboards/
```

This is already present in the existing compose; the subfolder `xrd/` will be picked up automatically.

### 2.7 `grafana/dashboards/xrd/xrd-sr-overview.json` — Dashboard

Create the directory `grafana/dashboards/xrd/` and build a dashboard JSON with the following specification. The implementing agent must generate the full Grafana dashboard JSON.

**Dashboard metadata:**

- `title`: `XRd SR Topology Overview`
- `uid`: `xrd-sr-overview`
- `tags`: `["xrd", "segment-routing", "cisco-live"]`
- `refresh`: `10s`
- `time`: last 30 minutes
- `timezone`: `browser`

**All rows are expanded (collapsed: false).**

#### Row 1: Network Health (stat panels)

| Panel                    | Query (PromQL)                                                           | Thresholds       |
| ------------------------ | ------------------------------------------------------------------------ | ---------------- |
| Interfaces UP            | `count(interfaces_interface_state_oper_status == 1)`                     | green ≥1, red =0 |
| Interfaces DOWN          | `count(interfaces_interface_state_oper_status == 0)`                     | green =0, red ≥1 |
| ISIS Adjacencies UP      | `count(network_instance_protocol_isis_adjacency_state == 1)`             | green ≥1, red =0 |
| ISIS Adjacencies DOWN    | `count(network_instance_protocol_isis_adjacency_state == 0)`             | green =0, red ≥1 |
| BGP Sessions ESTABLISHED | `count(network_instance_protocol_bgp_neighbor_state_session_state == 1)` | green ≥1, red =0 |
| BGP Sessions DOWN        | `count(network_instance_protocol_bgp_neighbor_state_session_state == 0)` | green =0, red ≥1 |

> **Note to implementing agent**: gNMIc metric names are derived from the gNMI path with `/` replaced by `_` and `[key=*]` keys stripped or used as labels. Verify exact metric names from Prometheus after Phase 1 is complete using: `curl -s http://localhost:9090/api/v1/label/__name__/values | python3 -m json.tool`

#### Row 2: Interfaces

| Panel                      | Type                    | Query                                                                | Description                                        |
| -------------------------- | ----------------------- | -------------------------------------------------------------------- | -------------------------------------------------- |
| Interface State per Device | State timeline or Table | `interfaces_interface_state_oper_status` grouped by `target`, `name` | Shows each device's interface oper state over time |
| TX Rate (bps)              | Time series             | `interfaces_interface_state_counters_out_octets * 8` rate per device | Outbound throughput                                |
| RX Rate (bps)              | Time series             | `interfaces_interface_state_counters_in_octets * 8` rate per device  | Inbound throughput                                 |

#### Row 3: ISIS

| Panel                | Type           | Query                                                                                | Description                                                       |
| -------------------- | -------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| ISIS Adjacency State | State timeline | `network_instance_protocol_isis_adjacency_state` grouped by `target`, `interface_id` | Shows per-device adjacency health over time; goes red during demo |
| SPF Runs             | Time series    | `network_instance_protocol_isis_global_counters_spf_runs_total` or equivalent        | Spike indicates re-convergence after interface failure            |

#### Row 4: BGP

| Panel             | Type           | Query                                                                                                | Description          |
| ----------------- | -------------- | ---------------------------------------------------------------------------------------------------- | -------------------- |
| BGP Session State | State timeline | `network_instance_protocol_bgp_neighbor_state_session_state` grouped by `target`, `neighbor_address` | vRR peer sessions    |
| Prefixes Received | Time series    | `network_instance_protocol_bgp_neighbor_state_prefixes_received`                                     | Route count changes  |
| Prefixes Sent     | Time series    | `network_instance_protocol_bgp_neighbor_state_prefixes_sent`                                         | Route advertisements |

#### Row 5: Segment Routing

| Panel              | Type  | Query                                          | Description                   |
| ------------------ | ----- | ---------------------------------------------- | ----------------------------- |
| MPLS Label Usage   | Gauge | `mpls_lsd_label_summary`                       | Labels allocated vs available |
| PCE Topology Nodes | Stat  | `pce_topology_summary` node count (xrd-7 only) | PCE view of network           |

#### Row 6: System Health

| Panel                   | Type                 | Query                                                   | Description       |
| ----------------------- | -------------------- | ------------------------------------------------------- | ----------------- |
| CPU % per Device        | Gauge or time series | `system_monitoring_cpu_utilization` grouped by `target` | Per-device CPU    |
| Memory Usage per Device | Gauge or time series | `memory_summary` grouped by `target`                    | Per-device memory |

#### Row 7: Logs

| Panel      | Type       | Config                                                                              |
| ---------- | ---------- | ----------------------------------------------------------------------------------- |
| XRd Syslog | Logs panel | Datasource: Loki; Query: `{job="xrd-syslog"}`; Show time; Dedup lines; Newest first |

During the demo, filter this panel to the affected device using a dashboard variable `$device` (add a variable of type `label_values(interfaces_interface_state_oper_status, target)` and propagate it to both Prometheus and Loki queries).

---

## Phase 3: Alerting

**Goal**: Define Grafana alert rules that fire on interface down and ISIS adjacency loss. Configure a webhook contact point. Validate by manually shutting an XRd interface.

**Done when**: Shutting down an interface on xrd-1 causes a Grafana alert to fire within 60 seconds, and the webhook endpoint receives a POST with the correct payload fields.

### 3.1 `grafana/provisioning/alerting/` — New directory

Create `grafana/provisioning/alerting/xrd-contact-points.yaml`:

```yaml
apiVersion: 1

contactPoints:
  - orgId: 1
    name: xrd-webhook
    receivers:
      - uid: xrd-webhook-recv
        type: webhook
        settings:
          url: "${WEBHOOK_RECEIVER_URL}"
          httpMethod: POST
        disableResolveMessage: false
```

> `WEBHOOK_RECEIVER_URL` is an environment variable set in `compose.yaml` or a `.env` file. In Phase 3 (before the FastAPI receiver exists), point this to a request bin (e.g. <https://webhook.site>) for testing.

Create `grafana/provisioning/alerting/xrd-alert-rules.yaml`:

```yaml
apiVersion: 1

groups:
  - orgId: 1
    name: xrd-interface-alerts
    folder: XRd Alerts
    interval: 10s
    rules:
      - uid: xrd-iface-down
        title: XRd Interface Down
        condition: C
        for: 10s
        annotations:
          summary: "Interface {{ $labels.name }} on {{ $labels.target }} is DOWN"
          description: "Interface operational status dropped to 0 (DOWN)"
        labels:
          event_type: interface_state
          affected_object_type: interface
          severity: critical
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: interfaces_interface_state_oper_status == 0
              instant: true
          - refId: C
            datasourceUid: "__expr__"
            model:
              type: classic_conditions
              conditions:
                - evaluator:
                    type: gt
                    params: [0]
                  operator:
                    type: and
                  query:
                    params: [A]
                  reducer:
                    type: count

      - uid: xrd-isis-adj-down
        title: XRd ISIS Adjacency Down
        condition: C
        for: 15s
        annotations:
          summary: "ISIS adjacency down on {{ $labels.target }}"
          description: "ISIS adjacency state dropped to 0 on interface {{ $labels.interface_id }}"
        labels:
          event_type: protocol_adjacency
          affected_object_type: isis_adjacency
          protocol: isis
          severity: critical
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: network_instance_protocol_isis_adjacency_state == 0
              instant: true
          - refId: C
            datasourceUid: "__expr__"
            model:
              type: classic_conditions
              conditions:
                - evaluator:
                    type: gt
                    params: [0]
                  operator:
                    type: and
                  query:
                    params: [A]
                  reducer:
                    type: count

      - uid: xrd-bgp-session-down
        title: XRd BGP Session Down
        condition: C
        for: 15s
        annotations:
          summary: "BGP session down on {{ $labels.target }} with neighbor {{ $labels.neighbor_address }}"
          description: "BGP session state is not ESTABLISHED"
        labels:
          event_type: bgp_session
          affected_object_type: bgp_neighbor
          protocol: bgp
          severity: critical
        data:
          - refId: A
            datasourceUid: prometheus
            model:
              expr: network_instance_protocol_bgp_neighbor_state_session_state == 0
              instant: true
          - refId: C
            datasourceUid: "__expr__"
            model:
              type: classic_conditions
              conditions:
                - evaluator:
                    type: gt
                    params: [0]
                  operator:
                    type: and
                  query:
                    params: [A]
                  reducer:
                    type: count
```

Mount the alerting directory in `compose.yaml` Grafana volumes:

```yaml
- ./grafana/provisioning/alerting/:/etc/grafana/provisioning/alerting/:ro
```

Also set the default contact point in `grafana/provisioning/alerting/xrd-notification-policy.yaml`:

```yaml
apiVersion: 1

policies:
  - orgId: 1
    receiver: xrd-webhook
    group_by: [target, event_type]
    group_wait: 10s
    group_interval: 10s
    repeat_interval: 1h
```

### 3.2 Environment variable for webhook URL

Add to `compose.yaml` Grafana environment:

```yaml
environment:
  - GF_SECURITY_ADMIN_PASSWORD=grafana
  - GF_UNIFIED_ALERTING_ENABLED=true
  - WEBHOOK_RECEIVER_URL=${WEBHOOK_RECEIVER_URL:-https://webhook.site/your-test-id}
```

Create `.env.example` at repo root:

```
# URL where Grafana sends alert webhooks
# In Phase 3: use https://webhook.site for testing
# In Phase 4: use http://<laptop-ip>:8080/alert
WEBHOOK_RECEIVER_URL=https://webhook.site/your-test-id
```

### 3.3 Validation — Phase 3

Trigger the primary demo scenario manually:

```bash
# SSH to xrd-1 and shut an interface
ssh cisco@10.10.20.101 "conf t
interface GigabitEthernet0/0/0/0
shutdown
commit
end"

# Watch Grafana fire the alert (check webhook.site or your receiver)
# Wait up to 60 seconds

# Restore
ssh cisco@10.10.20.101 "conf t
interface GigabitEthernet0/0/0/0
no shutdown
commit
end"
```

Verify the Grafana webhook POST body contains:

- `alerts[].labels.target` = `xrd-1`
- `alerts[].labels.event_type` = `interface_state`
- `alerts[].status` = `firing`

---

## Phase 4: Webhook Integration (FastAPI Receiver)

**Goal**: Build a FastAPI service that receives Grafana webhooks, transforms them into the alert schema, and kicks off a LangGraph investigation thread in sp_oncall.

**Done when**: Interface down on xrd-1 → Grafana fires → FastAPI receiver → sp_oncall agents investigate → report generated without human input.

### 4.1 Alert payload schema

The FastAPI receiver translates the Grafana native webhook body into this canonical schema before forwarding to sp_oncall:

```json
{
  "alert_name": "XRd Interface Down",
  "severity": "critical",
  "timestamp": "2026-05-20T10:23:00Z",
  "duration_seconds": 30,

  "device": "xrd-1",

  "event_type": "interface_state",
  "affected_object": "GigabitEthernet0/0/0/0",
  "affected_object_type": "interface",
  "previous_state": "up",
  "current_state": "down",

  "protocol": "isis",
  "network_instance": "default",
  "neighbor_device": "xrd-3",

  "metric_value": 0,
  "threshold": 1
}
```

**Field mapping from Grafana webhook → alert schema:**

| Alert schema field     | Source in Grafana payload                                                        |
| ---------------------- | -------------------------------------------------------------------------------- |
| `alert_name`           | `alerts[0].labels.alertname`                                                     |
| `severity`             | `alerts[0].labels.severity`                                                      |
| `timestamp`            | `alerts[0].startsAt` (parse to RFC3339)                                          |
| `duration_seconds`     | `(now - startsAt).seconds`                                                       |
| `device`               | `alerts[0].labels.target`                                                        |
| `event_type`           | `alerts[0].labels.event_type`                                                    |
| `affected_object`      | `alerts[0].labels.name` (interface) or `alerts[0].labels.neighbor_address` (BGP) |
| `affected_object_type` | `alerts[0].labels.affected_object_type`                                          |
| `previous_state`       | hardcoded `"up"` for firing alerts                                               |
| `current_state`        | hardcoded `"down"` for firing alerts                                             |
| `protocol`             | `alerts[0].labels.protocol` (may be null)                                        |
| `network_instance`     | `alerts[0].labels.network_instance` (may be null)                                |
| `neighbor_device`      | `alerts[0].labels.neighbor_device` (may be null)                                 |
| `metric_value`         | `alerts[0].values.B` or similar (depends on alert query)                         |
| `threshold`            | hardcoded `1` for state-based alerts                                             |

Fields that cannot be derived from the Grafana payload are `null`. The sp_oncall agents use gNMIBuddy MCP tools to fill in gaps (e.g. identifying the ISIS neighbor that was lost, the device role).

### 4.2 FastAPI receiver

Create a directory `webhook/` at the gnp-stack repo root. The receiver is a standalone FastAPI application.

**File structure:**

```
webhook/
├── main.py
├── schema.py
├── langgraph_client.py
├── pyproject.toml
└── Dockerfile
```

**`webhook/schema.py`** — Pydantic models:

- `GrafanaAlert`: models the incoming Grafana webhook body
- `NetworkAlert`: the canonical alert schema above

**`webhook/main.py`** — FastAPI app:

- `POST /alert` endpoint
- Validates incoming Grafana webhook
- Transforms to `NetworkAlert`
- Calls `langgraph_client.trigger_investigation(alert)`
- Returns `{"status": "accepted"}` immediately (do not wait for investigation)

**`webhook/langgraph_client.py`** — sp_oncall integration:

- Uses the LangGraph SDK (`langgraph_sdk`) to create a new thread and run
- Thread input is the `NetworkAlert` as a dict
- The sp_oncall graph entrypoint accepts this as its initial state
- Connection: `LANGGRAPH_API_URL` env var (default `http://localhost:2024`)

**`webhook/pyproject.toml`:**

```toml
[project]
name = "xrd-webhook-receiver"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.32.0",
    "langgraph-sdk>=0.1.0",
    "pydantic>=2.0.0",
]
```

**`compose.yaml`** — add webhook service:

```yaml
webhook-receiver:
  build: ./webhook
  ports:
    - 8080:8080
  environment:
    - LANGGRAPH_API_URL=${LANGGRAPH_API_URL:-http://host.docker.internal:2024}
  networks:
    - gnp-mgmt
```

Update `WEBHOOK_RECEIVER_URL` in `.env`:

```
WEBHOOK_RECEIVER_URL=http://<laptop-ip>:8080/alert
```

> sp_oncall runs on the laptop. The `LANGGRAPH_API_URL` uses `host.docker.internal` to reach it from the container. On Linux (the VM), replace `host.docker.internal` with the host's actual IP (`172.17.0.1` or the gnp-mgmt gateway IP).

### 4.3 Validation — Phase 4

```bash
# 1. Start sp_oncall on laptop (see sp_oncall README)
make -C ~/sp_oncall run

# 2. Start gnp-stack on VM with webhook receiver
make up

# 3. Update .env with real laptop IP
echo "WEBHOOK_RECEIVER_URL=http://$(curl -s ifconfig.me):8080/alert" >> .env
make restart

# 4. Trigger the scenario
ssh cisco@10.10.20.101 "conf t ; interface GigabitEthernet0/0/0/0 ; shutdown ; commit ; end"

# 5. Watch sp_oncall LangGraph Studio for a new thread starting
# Thread should show Input Validator → Planner → Executor → Assessor → Reporter
# Final report should identify the interface failure and ISIS impact

# 6. Restore
ssh cisco@10.10.20.101 "conf t ; interface GigabitEthernet0/0/0/0 ; no shutdown ; commit ; end"
```

---

## Appendix A: gNMI Path Reference

All paths confirmed against IOS-XR 25.3.1 via gNMIBuddy unless marked _[to validate]_.

### OpenConfig (primary)

| Data                   | Path                                                                                                                                                                                                 |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Interface oper-status  | `/interfaces/interface[name=*]/state/oper-status`                                                                                                                                                    |
| Interface admin-status | `/interfaces/interface[name=*]/state/admin-status`                                                                                                                                                   |
| Interface counters     | `/interfaces/interface[name=*]/state/counters`                                                                                                                                                       |
| ISIS adjacency state   | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/interfaces/interface[name=*]/levels/level[level-number=*]/adjacencies/adjacency/adjacency-state`       |
| ISIS neighbor IPv4     | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/interfaces/interface[name=*]/levels/level[level-number=*]/adjacencies/adjacency/neighbor-ipv4-address` |
| ISIS global counters   | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=ISIS][name=*]/isis/global/counters`                                                                                       |
| BGP session state      | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/session-state`                                              |
| BGP message counters   | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/messages`                                                   |
| BGP prefix counts      | `/network-instances/network-instance[name=*]/protocols/protocol[identifier=BGP][name=*]/bgp/neighbors/neighbor[neighbor-address=*]/state/prefixes`                                                   |

### XR Native YANG (for richer dashboard, validate in Phase 1)

| Data                      | Path                                                              |
| ------------------------- | ----------------------------------------------------------------- |
| CPU utilization           | `Cisco-IOS-XR-wdsysmon-fd-oper:system-monitoring/cpu-utilization` |
| Memory summary            | `Cisco-IOS-XR-nto-misc-oper:memory-summary/nodes/node/summary`    |
| MPLS label summary        | `Cisco-IOS-XR-mpls-lsd-oper:mpls-lsd/label-summary`               |
| PCE topology (xrd-7 only) | `Cisco-IOS-XR-infra-xtc-oper:pce/topology-summary`                |

---

## Appendix B: Alert Payload Schema (canonical)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "NetworkAlert",
  "type": "object",
  "required": ["alert_name", "severity", "timestamp", "device", "event_type"],
  "properties": {
    "alert_name": { "type": "string" },
    "severity": { "type": "string", "enum": ["critical", "warning", "info"] },
    "timestamp": { "type": "string", "format": "date-time" },
    "duration_seconds": { "type": ["integer", "null"] },
    "device": {
      "type": "string",
      "description": "Device hostname as known to gNMIBuddy"
    },
    "event_type": {
      "type": "string",
      "enum": [
        "interface_state",
        "protocol_adjacency",
        "bgp_session",
        "sr_path",
        "system_resource"
      ]
    },
    "affected_object": {
      "type": ["string", "null"],
      "description": "Interface name, neighbor IP, policy name, etc."
    },
    "affected_object_type": {
      "type": ["string", "null"],
      "enum": [
        "interface",
        "isis_adjacency",
        "bgp_neighbor",
        "sr_policy",
        "mpls_label",
        null
      ]
    },
    "previous_state": { "type": ["string", "null"] },
    "current_state": { "type": ["string", "null"] },
    "protocol": {
      "type": ["string", "null"],
      "enum": ["isis", "bgp", "mpls", "sr-te", "system", null]
    },
    "network_instance": { "type": ["string", "null"] },
    "neighbor_device": { "type": ["string", "null"] },
    "metric_value": { "type": ["number", "null"] },
    "threshold": { "type": ["number", "null"] }
  }
}
```

---

## Appendix C: File Change Summary per Phase

| File                                                         | Phase | Action                                     |
| ------------------------------------------------------------ | ----- | ------------------------------------------ |
| `Makefile`                                                   | 1     | Create                                     |
| `gnmic/gnmic-ingestor.yaml`                                  | 1     | Modify (add XRd subscriptions and output)  |
| `gnmic/gnmic-emitter.yaml`                                   | 1     | Modify (add XRd input and processor)       |
| `compose.yaml`                                               | 2, 4  | Modify (add Loki, Alloy, webhook services) |
| `loki/loki-config.yaml`                                      | 2     | Create                                     |
| `alloy/config.alloy`                                         | 2     | Create                                     |
| `grafana/provisioning/datasource.yaml`                       | 2     | Modify (add Loki datasource)               |
| `grafana/provisioning/dashboards.yaml`                       | 2     | Modify (add XRd folder)                    |
| `grafana/dashboards/xrd/xrd-sr-overview.json`                | 2     | Create                                     |
| `grafana/provisioning/alerting/xrd-contact-points.yaml`      | 3     | Create                                     |
| `grafana/provisioning/alerting/xrd-alert-rules.yaml`         | 3     | Create                                     |
| `grafana/provisioning/alerting/xrd-notification-policy.yaml` | 3     | Create                                     |
| `.env.example`                                               | 3     | Create                                     |
| `webhook/main.py`                                            | 4     | Create                                     |
| `webhook/schema.py`                                          | 4     | Create                                     |
| `webhook/langgraph_client.py`                                | 4     | Create                                     |
| `webhook/pyproject.toml`                                     | 4     | Create                                     |
| `webhook/Dockerfile`                                         | 4     | Create                                     |

---

## References

- gNMIBuddy (MCP tool for XRd): <https://github.com/jillesca/gNMIBuddy>
- sp_oncall (LangGraph agents): <https://github.com/jillesca/sp_oncall>
- XRd Sandbox topology: <https://github.com/CiscoDevNet/XRd-Sandbox/tree/main/topologies/segment-routing>
- Previous TIG demo (prior art): <https://github.com/jillesca/oncall-netops-tig-pyats-demo>
- gnp-stack upstream: this repo
- gNMIc documentation: <https://gnmic.openconfig.net>
- Grafana Alloy syslog: <https://grafana.com/docs/alloy/latest/reference/components/loki.source.syslog/>
- LangGraph SDK: <https://langchain-ai.github.io/langgraph/cloud/reference/sdk/python_sdk_ref/>
