# Modem Doctor

[![License](https://img.shields.io/github/license/francesco-carrella/openwrt-modem-doctor?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/francesco-carrella/openwrt-modem-doctor?style=flat-square)](../../releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-22.03+-blue?style=flat-square&logo=openwrt)](https://openwrt.org)

**OpenWrt package that fixes bufferbloat and monitors connectivity on LTE/5G modems.**

Modem Doctor auto-configures CAKE traffic shaping, disables hardware offloading that bypasses it, and runs a watchdog that detects high latency or connection drops — automatically recovering by reselecting a better cell tower. Includes a LuCI web interface for configuration and real-time status monitoring.

> **Status:** Early release. Developed and tested on a single device (GL-E750 Mudi V2 with Quectel EM060K-GL, OpenWrt 22.03). The core fixes (SQM/CAKE, queue tuning, GRO, TCP) are standard Linux networking and should work on any OpenWrt router with a cellular modem. The AT command layer currently targets Quectel modems. Feedback and testing on other hardware is welcome.

## Features

- **SQM/CAKE Traffic Shaping** — Auto-configures CAKE qdisc to prevent bufferbloat, the main cause of latency spikes under load
- **Hardware Offloading Management** — Detects and disables Qualcomm SFE which silently bypasses CAKE, making traffic shaping ineffective
- **Smart Watchdog** — Monitors connectivity and latency with progressive recovery (interface restart -> airplane mode toggle -> hard modem reset) and exponential backoff
- **Cell Reselection** — Automatically forces the modem to find a better tower when latency exceeds the threshold
- **Modem Tweaks** — Reduces TX queue length, disables GRO, disables modem sleep, tunes TCP at boot
- **LuCI Web Interface** — Real-time modem status dashboard with signal quality, temperature, and configuration UI
- **AT Command Abstraction** — Automatically detects gl_modem, sms_tool, comgt, or direct serial

## What It Fixes

| Problem | Cause | Fix |
|---------|-------|-----|
| Latency spikes under load (1-3s+) | Bufferbloat in modem queue | CAKE traffic shaping |
| CAKE not working on forwarded traffic | Hardware offloading (SFE) bypassing tc | Auto-disable SFE modules |
| Random latency spikes at idle | Modem sleep mode wake-up | AT+QSCLK=0 |
| Jitter from packet batching | GRO aggregating packets | Disable GRO on wwan |
| TCP performance drops after idle | Slow start after idle | sysctl tuning |
| Stuck on bad cell tower | No automatic reselection | Watchdog with airplane mode toggle |
| Connection drops | Modem/interface hangs | Progressive recovery escalation |

## Compatibility

### Tested

| Router | Modem | OpenWrt | Status |
|--------|-------|---------|--------|
| GL-E750 Mudi V2 | Quectel EM060K-GL (4G LTE Cat 6) | 22.03 | Working |

### Expected Compatible

The AT command library handles both modern and legacy Quectel command formats. These modems use the same AT interface and should work, but have not been tested:

- **Modern Quectel (5G):** RM500Q-GL, RM520N-GL
- **Legacy Quectel (4G):** EC25, EG25-G, EP06-E/A, EM06, BG96

If you test on any of these, please [open an issue](../../issues) with your results.

### Other Modem Brands

Most of modem-doctor's value comes from Linux kernel-level fixes (SQM/CAKE, TX queue tuning, GRO disable, TCP tuning) and 3GPP standard AT commands (AT+CFUN for recovery). These work with any cellular modem. The hardware offloading disable currently targets Qualcomm SFE as found on GL.iNet routers — other offloading engines (MediaTek HNAT, nftables flow offload) are not yet handled. Sleep mode disable (AT+QSCLK) and signal monitoring are Quectel-specific. Contributions for other chipsets and routers are welcome.

## Requirements

- OpenWrt 22.03 (tested; newer versions should work)
- A Quectel LTE/5G modem (see [Compatibility](#compatibility))
- Dependencies installed automatically: `comgt`, `jsonfilter`, `ethtool`, `sqm-scripts`, `kmod-sched-cake`

## Installation

### From .ipk packages (recommended)

Download the latest `.ipk` files from [Releases](../../releases), then:

```sh
# -O flag required for OpenWrt's Dropbear SSH (no sftp-server)
scp -O modem-doctor_*.ipk luci-app-modem-doctor_*.ipk root@192.168.8.1:/tmp/

ssh root@192.168.8.1 'opkg install /tmp/modem-doctor_*.ipk /tmp/luci-app-modem-doctor_*.ipk'
```

### From OpenWrt feed

Add to your `feeds.conf.default`:

```
src-git modem_doctor https://github.com/francesco-carrella/openwrt-modem-doctor.git
```

Then:

```sh
./scripts/feeds update modem_doctor
./scripts/feeds install -a -p modem_doctor
make menuconfig  # Select Network -> modem-doctor and LuCI -> luci-app-modem-doctor
make package/modem-doctor/compile
make package/luci-app-modem-doctor/compile
```

### Enable

Via LuCI: navigate to **Services -> Modem Doctor -> Configuration** and enable.

Or via CLI:

```sh
uci set modem-doctor.main.enabled=1
uci commit modem-doctor
/etc/init.d/modem-doctor start
```

## How It Works

### Traffic Shaping (SQM/CAKE)

At startup, Modem Doctor:

1. **Disables hardware offloading (SFE)** — Qualcomm's Shortcut Forwarding Engine fast-paths packets around the Linux networking stack, completely bypassing CAKE. Modem Doctor unloads the SFE kernel modules so CAKE can shape all forwarded traffic.
2. **Configures CAKE** — Creates an SQM queue on the modem interface with CAKE qdisc, applying download/upload bandwidth limits. CAKE manages the packet queue to keep latency low even when the link is saturated.

Set bandwidth to ~80% of your measured connection speed. If set too high, the modem's internal queue fills up and CAKE can't help.

### Watchdog Loop

Every 2 minutes (configurable):

1. **Connectivity check** — Pings target (default 1.1.1.1). If all pings fail, progressive recovery:
   - Step 1: Interface restart (ifdown/ifup)
   - Step 2: Airplane mode toggle (AT+CFUN=4/1)
   - Step 3: Hard modem reset (AT+CFUN=1,1)
   - Exponential backoff prevents hammering during extended outages
2. **Latency check** — Measures average ping latency. If above threshold (default 500ms):
   - Forces cell reselection via airplane mode toggle

### Modem Tweaks

Applied once at service start:

- TX queue length set to 100 (stock is 1000 — prevents bufferbloat)
- GRO disabled on wwan device (prevents latency batching)
- Modem sleep disabled (AT+QSCLK=0 — prevents idle-to-active latency spikes)
- TCP slow start after idle disabled (sysctl)

All settings are individually toggleable via the LuCI configuration UI.

### AT Command Abstraction

Automatically detects and uses the best available method:

1. `gl_modem` — GL.iNet routers
2. `sms_tool` — 4IceG ecosystem
3. `comgt` — Standard OpenWrt
4. Direct serial — Fallback to /dev/ttyUSB2

## Project Structure

```
modem-doctor/                    # Backend package
├── Makefile
└── files/
    ├── etc/
    │   ├── config/modem-doctor          # Default UCI config
    │   ├── init.d/modem-doctor          # procd init script
    │   └── uci-defaults/80-modem-doctor # First-boot setup
    └── usr/
        ├── bin/
        │   ├── modem-doctor.sh          # Watchdog daemon
        │   └── modem-doctor-setup.sh    # Boot-time fixes + SQM config
        └── lib/modem-doctor/
            └── modem-doctor-lib.sh      # AT command abstraction

luci-app-modem-doctor/           # LuCI web interface package
├── Makefile
├── htdocs/.../view/modem-doctor/
│   ├── status.js                # Real-time status dashboard
│   └── config.js                # Configuration form
└── root/
    ├── etc/uci-defaults/        # LuCI cache clear
    └── usr/
        ├── libexec/rpcd/
        │   └── luci.modem-doctor        # rpcd JSON API
        └── share/
            ├── luci/menu.d/             # Menu entries
            ├── rpcd/acl.d/              # Access control
            └── ucitrack/                # UCI -> init linkage
```

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

```sh
# Deploy to router for testing
./deploy.sh root@192.168.8.1

# Build .ipk packages locally (without SDK)
./create-ipk.sh
```

## License

[Apache-2.0](LICENSE)
