#!/bin/sh
# modem-doctor-setup.sh — One-shot boot fixes for modem connection quality
# Called once at service start before the watchdog daemon begins
#
# Copyright (c) 2026 modem-doctor contributors
# Licensed under Apache-2.0

. /usr/lib/modem-doctor/modem-doctor-lib.sh
. /lib/functions.sh

config_load modem-doctor

# Read fix configuration
config_get TXQUEUELEN       fixes txqueuelen        "100"
config_get DISABLE_GRO      fixes disable_gro       "1"
config_get DISABLE_SLEEP     fixes disable_modem_sleep "1"
config_get TCP_NO_SLOW_START fixes tcp_no_slow_start "1"

# Read SQM configuration
config_get CONFIGURE_SQM    sqm configure_sqm       "1"
config_get SQM_DOWNLOAD     sqm download            "48000"
config_get SQM_UPLOAD       sqm upload              "24000"
config_get DISABLE_SFE      sqm disable_sfe         "1"

# Initialize modem detection
mdd_detect_at_method

# Detect wwan device
WWAN=$(mdd_detect_wwan)

if [ -z "$WWAN" ]; then
	mdd_log warn "Setup: no wwan device found, skipping network fixes"
else
	# Reduce transmit queue length (anti-bufferbloat)
	if [ -n "$TXQUEUELEN" ] && [ "$TXQUEUELEN" -gt 0 ] 2>/dev/null; then
		ip link set "$WWAN" txqueuelen "$TXQUEUELEN" 2>/dev/null
		if [ $? -eq 0 ]; then
			mdd_log "Setup: set $WWAN txqueuelen=$TXQUEUELEN"
		else
			mdd_log warn "Setup: failed to set txqueuelen on $WWAN"
		fi
	fi

	# Disable Generic Receive Offload (prevents latency spikes)
	if [ "$DISABLE_GRO" = "1" ]; then
		ethtool -K "$WWAN" gro off 2>/dev/null
		if [ $? -eq 0 ]; then
			mdd_log "Setup: disabled GRO on $WWAN"
		else
			mdd_log warn "Setup: ethtool not available or GRO disable failed on $WWAN"
		fi
	fi
fi

# Disable modem sleep mode (prevents latency spikes from idle->active transitions)
if [ "$DISABLE_SLEEP" = "1" ]; then
	# Wait for modem to be fully initialized
	retries=0
	while [ "$retries" -lt 10 ]; do
		resp=$(mdd_send_at "AT")
		if echo "$resp" | grep -q "OK"; then
			break
		fi
		retries=$((retries + 1))
		sleep 3
	done

	mdd_disable_sleep
	mdd_log "Setup: disabled modem sleep (QSCLK=0)"
fi

# TCP tuning
if [ "$TCP_NO_SLOW_START" = "1" ]; then
	sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
	mdd_log "Setup: set tcp_slow_start_after_idle=0"
fi

# Disable Shortcut Forwarding Engine (incompatible with CAKE)
# SFE fast-paths packets around the networking stack, completely bypassing
# tc/CAKE traffic shaping. This is an independent toggle — SFE should be
# disabled whether or not modem-doctor manages SQM.
if [ "$DISABLE_SFE" = "1" ]; then
	if lsmod | grep -q shortcut_fe; then
		rmmod shortcut_fe_cm 2>/dev/null
		rmmod shortcut_fe_ipv6 2>/dev/null
		rmmod shortcut_fe 2>/dev/null
		rmmod gl_sdk4_tertf 2>/dev/null
		mdd_log "Setup: disabled Shortcut Forwarding Engine (incompatible with CAKE)"
	fi
fi

# SQM/CAKE auto-configuration
# Only configure SQM if SFE is disabled (CAKE is useless when SFE bypasses it)
if [ "$CONFIGURE_SQM" = "1" ] && [ "$DISABLE_SFE" = "1" ] && [ -n "$WWAN" ]; then
	# Find existing SQM queue for this wwan device
	sqm_iface=""
	config_load sqm 2>/dev/null

	_mdd_find_sqm() {
		local cfg="$1"
		local iface
		config_get iface "$cfg" interface ""
		[ "$iface" = "$WWAN" ] && sqm_iface="$cfg"
	}
	config_foreach _mdd_find_sqm queue

	if [ -z "$sqm_iface" ]; then
		# No existing SQM config for this device — create one
		sqm_iface=$(uci add sqm queue)
		mdd_log "Setup: created SQM queue for $WWAN"
	fi

	uci -q batch <<-SQMEOF
		set sqm.$sqm_iface.enabled='1'
		set sqm.$sqm_iface.interface='$WWAN'
		set sqm.$sqm_iface.download='$SQM_DOWNLOAD'
		set sqm.$sqm_iface.upload='$SQM_UPLOAD'
		set sqm.$sqm_iface.qdisc='cake'
		set sqm.$sqm_iface.script='piece_of_cake.qos'
		set sqm.$sqm_iface.qdisc_advanced='1'
		set sqm.$sqm_iface.squash_dscp='1'
		set sqm.$sqm_iface.squash_ingress='1'
		set sqm.$sqm_iface.ingress_ecn='ECN'
		set sqm.$sqm_iface.egress_ecn='ECN'
		set sqm.$sqm_iface.linklayer='none'
		commit sqm
	SQMEOF

	/etc/init.d/sqm restart 2>/dev/null
	mdd_log "Setup: SQM/CAKE on $WWAN (down=${SQM_DOWNLOAD}kbps up=${SQM_UPLOAD}kbps)"
fi

mdd_log "Setup complete"
