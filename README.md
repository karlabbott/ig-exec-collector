# ig-exec-collector

A repeatable deployment of [Inspektor Gadget](https://github.com/inspektor-gadget/inspektor-gadget)'s `trace_exec` gadget that collects process execution events on Linux servers and sends them to Azure Log Analytics for monitoring and visualization in Grafana.

## Overview

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐     ┌─────────┐
│ Inspektor Gadget│────▶│ ig-collector  │────▶│ Azure Log       │────▶│ Grafana │
│ trace_exec      │     │ (Python)      │     │ Analytics       │     │         │
│ (eBPF)          │     │               │     │                 │     │         │
└─────────────────┘     └──────────────┘     └─────────────────┘     └─────────┘
```

The collector runs as a systemd service, batching exec events and sending them to Log Analytics via the HTTP Data Collector API. A Grafana dashboard template is included for visualization.

## Requirements

- **RHEL 10** (or compatible: Azure Linux, Fedora 38+)
- **Linux kernel 5.10+** with BTF enabled
- **Root access** (eBPF requires root)
- **Azure Log Analytics workspace** with workspace ID and shared key

## Quick Start

```bash
# Clone the repo
git clone https://github.com/karlabbott/ig-exec-collector.git
cd ig-exec-collector

# Run the installer (installs IG, collector, systemd service)
sudo ./install.sh

# Edit config with your Log Analytics credentials
sudo vi /etc/ig-collector/ig-collector.env

# Start the collector
sudo systemctl start ig-collector
```

## Installation

### What the installer does

1. Installs dependencies (`python3`, `curl`, `jq`)
2. Downloads and installs the latest Inspektor Gadget binary
3. Verifies kernel BTF support
4. Installs the collector script to `/opt/ig-collector/`
5. Creates a config file at `/etc/ig-collector/ig-collector.env`
6. Installs and enables a systemd service

### Configuration

Edit `/etc/ig-collector/ig-collector.env`:

```bash
# Required
LA_WORKSPACE_ID=your-workspace-id-here
LA_WORKSPACE_KEY=your-workspace-shared-key-here

# Optional
LA_LOG_TYPE=InspektorGadgetExec    # Custom log type name
IG_BATCH_SIZE=100                   # Records per batch
IG_FLUSH_INTERVAL=30                # Seconds between flushes
```

#### Getting Log Analytics credentials

```bash
# Workspace ID
az monitor log-analytics workspace show \
  --resource-group <rg> --workspace-name <name> \
  --query customerId -o tsv

# Shared Key
az monitor log-analytics workspace get-shared-keys \
  --resource-group <rg> --workspace-name <name> \
  --query primarySharedKey -o tsv
```

## Managing the Service

```bash
# Start/stop/restart
sudo systemctl start ig-collector
sudo systemctl stop ig-collector
sudo systemctl restart ig-collector

# Check status
sudo systemctl status ig-collector

# View logs
sudo journalctl -u ig-collector -f
```

## Data Schema

Each exec event is sent to Log Analytics as a custom log (`InspektorGadgetExec_CL`) with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `Timestamp` | datetime | UTC timestamp of the exec event |
| `Comm_s` | string | Command/process name |
| `Pid_d` | number | Process ID |
| `Tid_d` | number | Thread ID |
| `ParentComm_s` | string | Parent process name |
| `ParentPid_d` | number | Parent process ID |
| `Args_s` | string | Command arguments |
| `Uid_d` | number | User ID |
| `User_s` | string | Username |
| `ExecCount_d` | number | Always 1 (for aggregation) |

> Note: Log Analytics appends type suffixes (`_s` for string, `_d` for number, `_CL` for custom log).

## Grafana Dashboard

A pre-built dashboard template is included in `grafana/dashboard.json`.

### Dashboard panels

1. **Exec Calls Over Time** — time series of exec calls per minute
2. **Top Processes by Exec Count** — bar chart of most executed programs
3. **Exec Calls by User** — donut chart breakdown by user
4. **Total Exec Calls (Last Hour)** — stat panel with thresholds
5. **Unique Processes (Last Hour)** — stat panel
6. **Execs Per Minute (Avg)** — stat panel

### Importing to Azure Managed Grafana

Before importing, replace the template variables in `grafana/dashboard.json`:
- `${DS_AZURE_MONITOR}` → your Azure Monitor data source UID (e.g., `azure-monitor-oob`)
- `${LA_WORKSPACE_RESOURCE_ID}` → your full workspace resource ID

```bash
# Import via Azure CLI
az grafana dashboard create \
  --resource-group <rg> \
  --name <grafana-name> \
  --definition @grafana/dashboard.json
```

### Sample KQL Queries

```kusto
// Exec calls over time (1-minute buckets)
InspektorGadgetExec_CL
| summarize ExecCount=count() by bin(TimeGenerated, 1m)
| order by TimeGenerated asc

// Top 10 most executed commands
InspektorGadgetExec_CL
| where TimeGenerated > ago(1h)
| summarize Count=count() by Comm_s
| top 10 by Count

// Exec calls by user
InspektorGadgetExec_CL
| where TimeGenerated > ago(1h)
| summarize Count=count() by User_s
| order by Count desc
```

## Uninstalling

```bash
sudo ./uninstall.sh
```

This stops the service and removes the collector. Config files in `/etc/ig-collector/` and the Inspektor Gadget binary are preserved (remove manually if desired).

## Deploying to Multiple Servers

For deploying across a fleet of RHEL 10 servers:

```bash
# Example with a loop over hosts
for host in server1 server2 server3; do
  scp -r ig-exec-collector/ user@$host:/tmp/ig-exec-collector/
  ssh user@$host "cd /tmp/ig-exec-collector && sudo ./install.sh"
  # Copy pre-filled env file
  scp ig-collector.env user@$host:/tmp/ig-collector.env
  ssh user@$host "sudo cp /tmp/ig-collector.env /etc/ig-collector/ig-collector.env && sudo systemctl start ig-collector"
done
```

Or use your preferred configuration management tool (Ansible, Puppet, etc.).

## License

MIT
