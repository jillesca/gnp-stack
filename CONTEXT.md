# GNP-Stack Domain Glossary

This file is a glossary of canonical terms used in this project.
It does **not** contain implementation details, architecture decisions, or specs — those live in DESIGN.md and DESIGN-ADDENDUM.md.

---

## Terms

**Alert Scenario**
The demo sequence in which an XRd interface is manually brought down, producing a cascade of ISIS adjacency losses and triggering the Grafana alerting pipeline. Visualised in the "Alert Scenario" dashboard row.

**Devices Monitored**
The count of unique XRd devices that are actively reporting at least one telemetry metric to Prometheus at the time of query. Distinct from _devices configured_: a device is Monitored only while its gNMI subscription is healthy.

**Option A / Option B**
Two complementary views of the ISIS impact during an Alert Scenario. Option A is a state-timeline showing every source→neighbour pair individually; Option B is a single timeseries counting total adjacencies UP over time. Both panels are kept on the dashboard so the operator can choose which to highlight for their audience.

**Interface Flap**
A single up→down or down→up transition on a physical interface. Measured with `changes()` over the selected time window. A stable topology has zero flaps; an unstable interface accumulates flaps rapidly.

**Subscription**
A gNMI stream configured in `gnmic-ingestor.yaml` that collects a specific YANG path from one or more XRd targets and forwards it to NATS JetStream. Each subscription has a mode (stream/sample), a sample-interval, and a list of target paths.
