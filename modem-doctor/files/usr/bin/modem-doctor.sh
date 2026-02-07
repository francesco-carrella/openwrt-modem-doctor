#!/bin/sh
# modem-doctor.sh — Modem connection watchdog daemon
# Monitors connectivity and latency, takes progressive recovery actions
# Managed by procd — runs as a continuous daemon
#
# Copyright (c) 2026 modem-doctor contributors
# Licensed under Apache-2.0

. /usr/lib/modem-doctor/modem-doctor-lib.sh
. /lib/functions.sh

# Load configuration
config_load modem-doctor

config_get PING_TARGET  watchdog ping_target    "1.1.1.1"
config_get PING_COUNT   watchdog ping_count     "3"
config_get PING_TIMEOUT watchdog ping_timeout   "5"
config_get LATENCY_THR  watchdog latency_threshold "500"
config_get LATENCY_PINGS watchdog latency_pings "20"
config_get INTERVAL     watchdog interval       "120"
config_get RECOVERY_WAIT watchdog recovery_wait "15"

# Detect modem and interface
mdd_init

IFACE=$(mdd_detect_interface)
WWAN=$(mdd_detect_wwan)

# Recovery backoff: consecutive failures increase wait between aggressive actions
FAIL_COUNT=0
MAX_BACKOFF=4  # max multiplier: 2^4 = 16x interval

mdd_log "Watchdog starting: model=$MDD_MODEM_MODEL iface=$IFACE wwan=$WWAN target=$PING_TARGET threshold=${LATENCY_THR}ms interval=${INTERVAL}s"

# --- Signal handling for clean procd shutdown ---

SLEEP_PID=""

clean_up() {
	mdd_log "Received SIGTERM, shutting down"
	[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
	rm -f /tmp/modem-doctor-state.tmp
	exit 0
}

trap clean_up TERM INT

# Interruptible sleep: allows SIGTERM to be delivered during sleep
daemon_sleep() {
	sleep "$1" &
	SLEEP_PID=$!
	wait "$SLEEP_PID" 2>/dev/null
	SLEEP_PID=""
}

# --- State file (atomic write via temp + mv) ---

# Write complete state file for rpcd plugin to read
# All modem data is collected here — rpcd never sends AT commands
write_state() {
	local action="${1:-none}"
	local action_time="${2:-0}"
	local avg_latency="${3:-0}"
	local tmp="/tmp/modem-doctor-state.tmp"
	local state_file="/tmp/modem-doctor-state"

	# Collect signal data from modem
	local signal_data
	signal_data=$(mdd_get_signal 2>/dev/null)
	local rat band rsrp rsrq rssi sinr cellid earfcn conn_state mcc mnc
	rat=$(echo "$signal_data" | grep "^rat=" | cut -d= -f2)
	band=$(echo "$signal_data" | grep "^band=" | cut -d= -f2)
	rsrp=$(echo "$signal_data" | grep "^rsrp=" | cut -d= -f2)
	rsrq=$(echo "$signal_data" | grep "^rsrq=" | cut -d= -f2)
	rssi=$(echo "$signal_data" | grep "^rssi=" | cut -d= -f2)
	sinr=$(echo "$signal_data" | grep "^sinr=" | cut -d= -f2)
	cellid=$(echo "$signal_data" | grep "^cellid=" | cut -d= -f2)
	earfcn=$(echo "$signal_data" | grep "^earfcn=" | cut -d= -f2)
	conn_state=$(echo "$signal_data" | grep "^state=" | cut -d= -f2)
	mcc=$(echo "$signal_data" | grep "^mcc=" | cut -d= -f2)
	mnc=$(echo "$signal_data" | grep "^mnc=" | cut -d= -f2)

	# Collect temperature
	local temp
	temp=$(mdd_get_temp 2>/dev/null)

	# Write to temp file, then atomic move
	cat > "$tmp" <<-EOF
		model=$MDD_MODEM_MODEL
		generation=$MDD_MODEM_GEN
		firmware=$MDD_MODEM_FW
		at_method=$MDD_AT_METHOD
		interface=$IFACE
		wwan=$WWAN
		last_check=$(date +%s)
		last_action=$action
		last_action_time=$action_time
		last_avg_latency=$avg_latency
		rat=${rat:-unknown}
		band=${band:-0}
		rsrp=${rsrp:-0}
		rsrq=${rsrq:-0}
		rssi=${rssi:-0}
		sinr=${sinr:-0}
		cellid=${cellid:-}
		earfcn=${earfcn:-0}
		conn_state=${conn_state:-unknown}
		mcc=${mcc:-}
		mnc=${mnc:-}
		temperature=${temp:-0}
		fail_count=$FAIL_COUNT
		version=$MDD_VERSION
	EOF
	mv "$tmp" "$state_file"
}

# Restart the modem network interface
restart_interface() {
	mdd_log "Restarting interface $IFACE"
	ifdown "$IFACE" 2>/dev/null
	sleep 5
	ifup "$IFACE" 2>/dev/null
	sleep "$RECOVERY_WAIT"
}

# Check if we can reach the ping target
check_connectivity() {
	local fail=0
	local i=1

	while [ "$i" -le "$PING_COUNT" ]; do
		if [ -n "$WWAN" ]; then
			ping -c 1 -W "$PING_TIMEOUT" -I "$WWAN" "$PING_TARGET" > /dev/null 2>&1 || fail=$((fail + 1))
		else
			ping -c 1 -W "$PING_TIMEOUT" "$PING_TARGET" > /dev/null 2>&1 || fail=$((fail + 1))
		fi
		[ "$i" -lt "$PING_COUNT" ] && sleep 1
		i=$((i + 1))
	done

	echo "$fail"
}

# Calculate average latency from ping output
measure_latency() {
	local ping_output
	if [ -n "$WWAN" ]; then
		ping_output=$(ping -c "$LATENCY_PINGS" -W 3 -I "$WWAN" "$PING_TARGET" 2>/dev/null)
	else
		ping_output=$(ping -c "$LATENCY_PINGS" -W 3 "$PING_TARGET" 2>/dev/null)
	fi

	local pings
	pings=$(echo "$ping_output" | grep "time=" | sed 's/.*time=//;s/ .*//' | cut -d. -f1)
	[ -z "$pings" ] && echo "0" && return 1

	local total=0 count=0
	for p in $pings; do
		total=$((total + p))
		count=$((count + 1))
	done

	[ "$count" -eq 0 ] && echo "0" && return 1
	echo $((total / count))
}

# Quick ping check after recovery action
verify_recovery() {
	sleep 2
	ping -c 2 -W 5 "$PING_TARGET" > /dev/null 2>&1
}

# Progressive recovery for total connection loss
# Uses backoff: after repeated failures, skip aggressive actions
handle_connection_loss() {
	local now=$(date +%s)
	FAIL_COUNT=$((FAIL_COUNT + 1))

	# Step 1: Interface restart (always try)
	mdd_log warn "Connection lost ($PING_COUNT/$PING_COUNT pings failed, attempt #$FAIL_COUNT). Restarting interface."
	write_state "interface_restart" "$now" "0"
	restart_interface
	verify_recovery && { FAIL_COUNT=0; return 0; }

	# Step 2: Airplane mode toggle (skip if too many consecutive failures)
	if [ "$FAIL_COUNT" -le 3 ]; then
		mdd_log warn "Interface restart failed. Toggling airplane mode."
		write_state "airplane_toggle" "$now" "0"
		mdd_airplane_toggle
		sleep 10
		restart_interface
		verify_recovery && { FAIL_COUNT=0; return 0; }
	else
		mdd_log info "Skipping airplane toggle (backoff: attempt #$FAIL_COUNT)"
	fi

	# Step 3: Hard modem reset (only on first 2 failures, then every 4th attempt)
	if [ "$FAIL_COUNT" -le 2 ] || [ $((FAIL_COUNT % 4)) -eq 0 ]; then
		mdd_log err "Airplane toggle failed. Hard modem reset."
		write_state "hard_reset" "$now" "0"
		mdd_hard_reset
		sleep 30
		restart_interface
		verify_recovery && { FAIL_COUNT=0; return 0; }
	else
		mdd_log info "Skipping hard reset (backoff: attempt #$FAIL_COUNT, next at #$((FAIL_COUNT + 4 - FAIL_COUNT % 4)))"
	fi

	return 1
}

# Handle high latency
handle_high_latency() {
	local avg="$1"
	local now=$(date +%s)

	mdd_log warn "High latency (avg ${avg}ms > ${LATENCY_THR}ms). Forcing cell reselection."
	write_state "cell_reselection" "$now" "$avg"

	mdd_airplane_toggle
	sleep 10
	restart_interface

	# Measure new latency
	local new_avg
	new_avg=$(measure_latency)
	mdd_log "After reselection: avg ${new_avg:-unknown}ms"
	write_state "cell_reselection_done" "$now" "$new_avg"
}

# --- Main Loop ---

write_state "started" "$(date +%s)" "0"

while true; do
	# Step 1: Connectivity check
	fail_count=$(check_connectivity)

	if [ "$fail_count" -ge "$PING_COUNT" ]; then
		handle_connection_loss
		write_state "recovery_complete" "$(date +%s)" "0"

		# Backoff sleep: double interval for each consecutive failure (capped)
		local backoff_exp=$FAIL_COUNT
		[ "$backoff_exp" -gt "$MAX_BACKOFF" ] && backoff_exp=$MAX_BACKOFF
		local backoff_interval=$((INTERVAL * (1 << backoff_exp)))
		if [ "$FAIL_COUNT" -gt 0 ]; then
			mdd_log info "Backoff: next check in ${backoff_interval}s (attempt #$FAIL_COUNT)"
			daemon_sleep "$backoff_interval"
		else
			daemon_sleep "$INTERVAL"
		fi
	else
		# Connection OK — reset failure counter
		FAIL_COUNT=0

		# Step 2: Latency check (only if connected)
		avg_latency=$(measure_latency)

		if [ -n "$avg_latency" ] && [ "$avg_latency" -gt 0 ] 2>/dev/null; then
			if [ "$avg_latency" -gt "$LATENCY_THR" ]; then
				handle_high_latency "$avg_latency"
			else
				write_state "ok" "$(date +%s)" "$avg_latency"
			fi
		fi

		daemon_sleep "$INTERVAL"
	fi
done
