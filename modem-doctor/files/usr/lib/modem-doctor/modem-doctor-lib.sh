#!/bin/sh
# modem-doctor-lib.sh — Shared library for modem-doctor
# Provides AT command abstraction, modem detection, signal/temp parsers
# Source this file: . /usr/lib/modem-doctor/modem-doctor-lib.sh
#
# Copyright (c) 2026 modem-doctor contributors
# Licensed under Apache-2.0

MDD_VERSION="1.0.0"
MDD_LOG_TAG="modem-doctor"

# Globals set by mdd_detect_modem
MDD_MODEM_MODEL=""
MDD_MODEM_GEN=""    # "legacy" or "modern"
MDD_MODEM_FW=""
MDD_AT_METHOD=""    # "gl_modem" | "sms_tool" | "comgt" | "direct"
MDD_AT_PORT=""      # e.g. /dev/ttyUSB2

# --- Logging ---

# Log with syslog priority: mdd_log "message" or mdd_log warn "message"
mdd_log() {
	local priority="info"
	case "$1" in
		err|warn|info|notice)
			priority="$1"
			shift
			;;
	esac
	logger -p "daemon.$priority" -t "$MDD_LOG_TAG[$$]" "$@"
}

# --- AT Command Abstraction ---

# Detect the best available method for sending AT commands
mdd_detect_at_method() {
	if command -v gl_modem >/dev/null 2>&1; then
		MDD_AT_METHOD="gl_modem"
	elif command -v sms_tool >/dev/null 2>&1; then
		MDD_AT_METHOD="sms_tool"
	elif command -v comgt >/dev/null 2>&1; then
		MDD_AT_METHOD="comgt"
	else
		MDD_AT_METHOD="direct"
	fi

	# Find AT port for direct/comgt methods
	if [ "$MDD_AT_METHOD" = "direct" ] || [ "$MDD_AT_METHOD" = "comgt" ]; then
		MDD_AT_PORT=$(mdd_find_at_port)
	fi
}

# Find the Quectel AT command port via sysfs
mdd_find_at_port() {
	local port=""

	# Method 1: Look for Quectel VID (2c7c) interface 2 in sysfs
	for dev in /sys/bus/usb/devices/*; do
		[ -f "$dev/idVendor" ] || continue
		local vid=$(cat "$dev/idVendor" 2>/dev/null)
		[ "$vid" = "2c7c" ] || continue

		# Found Quectel device, look for interface 2 (AT port)
		for iface in "$dev"/*:1.2; do
			[ -d "$iface" ] || continue
			for tty in "$iface"/ttyUSB*; do
				[ -d "$tty" ] || continue
				port="/dev/$(basename "$tty")"
				[ -c "$port" ] && echo "$port" && return 0
			done
		done
	done

	# Method 2: Fallback to /dev/ttyUSB2 if it exists
	[ -c "/dev/ttyUSB2" ] && echo "/dev/ttyUSB2" && return 0

	# Method 3: Try any ttyUSB device
	for p in /dev/ttyUSB*; do
		[ -c "$p" ] && echo "$p" && return 0
	done

	return 1
}

# Send an AT command and return the response
# Usage: mdd_send_at "AT+QTEMP"
mdd_send_at() {
	local cmd="$1"
	local response=""

	case "$MDD_AT_METHOD" in
		gl_modem)
			response=$(gl_modem AT "$cmd" 2>/dev/null)
			;;
		sms_tool)
			response=$(sms_tool at "$cmd" 2>/dev/null)
			;;
		comgt)
			response=$(comgt -d "$MDD_AT_PORT" -s /dev/stdin 2>/dev/null <<-COMGT
				opengt
				set com 115200n81
				set comecho off
				set senddelay 0.02
				waitquiet 0.2 0.2
				flash 0.1
				send "${cmd}^m"
				get 3 "" \$s
				print \$s
				exit 0
			COMGT
			)
			;;
		direct)
			if [ -n "$MDD_AT_PORT" ] && [ -c "$MDD_AT_PORT" ]; then
				# Configure port
				stty -F "$MDD_AT_PORT" 115200 raw -echo 2>/dev/null
				# Send command and read response
				printf '%s\r' "$cmd" > "$MDD_AT_PORT"
				response=$(timeout 3 cat "$MDD_AT_PORT" 2>/dev/null)
			fi
			;;
	esac

	# Strip \r from AT responses (modems use \r\n line endings)
	echo "$response" | tr -d '\r'
}

# --- Modem Detection ---

# Detect modem model and classify generation
mdd_detect_modem() {
	local ati_response
	ati_response=$(mdd_send_at "ATI")

	# Parse model from ATI response (second line after "Quectel")
	MDD_MODEM_MODEL=$(echo "$ati_response" | grep -v "^$" | grep -v "^OK" | grep -v "^ATI" | grep -v "^Quectel" | grep -v "^Revision" | head -1)
	# If that didn't work, try CGMM
	if [ -z "$MDD_MODEM_MODEL" ]; then
		MDD_MODEM_MODEL=$(mdd_send_at "AT+CGMM" | grep -v "^$" | grep -v "^OK" | grep -v "^AT+" | head -1)
	fi
	# Last resort: grep for known model names
	if [ -z "$MDD_MODEM_MODEL" ]; then
		MDD_MODEM_MODEL=$(echo "$ati_response" | grep -oE "(EC25|EG25-G|EP06|EM06|EM060K|RM500Q|RM520N|BG96)" | head -1)
	fi

	# Parse firmware revision
	MDD_MODEM_FW=$(echo "$ati_response" | grep "Revision:" | sed 's/.*Revision: *//')

	# Classify generation
	case "$MDD_MODEM_MODEL" in
		*EM060K*|*RM500Q*|*RM520N*|*RM530*|*RG50*|*RG52*)
			MDD_MODEM_GEN="modern"
			;;
		*EC25*|*EG25*|*EP06*|*EM06*|*EG06*|*EG12*|*BG96*|*BG95*)
			MDD_MODEM_GEN="legacy"
			;;
		*)
			# Unknown model — try to detect by checking which commands work
			local test=$(mdd_send_at 'AT+QNWPREFCFG="mode_pref"')
			if echo "$test" | grep -q "+QNWPREFCFG"; then
				MDD_MODEM_GEN="modern"
			else
				MDD_MODEM_GEN="legacy"
			fi
			;;
	esac
}

# --- Signal Quality ---

# Get signal info as key=value pairs (one per line)
# Output: rat=LTE band=3 rsrp=-95 rsrq=-11 sinr=8 cellid=ABC123 earfcn=1300 state=NOCONN
mdd_get_signal() {
	local response
	response=$(mdd_send_at 'AT+QENG="servingcell"')

	# Check which RAT we're on
	if echo "$response" | grep -q '"NR5G-SA"'; then
		mdd_parse_signal_nr5g_sa "$response"
	elif echo "$response" | grep -q '"NR5G-NSA"'; then
		mdd_parse_signal_nr5g_nsa "$response"
	elif echo "$response" | grep -q '"LTE"'; then
		mdd_parse_signal_lte "$response"
	elif echo "$response" | grep -q '"CAT-M"'; then
		mdd_parse_signal_lte "$response"  # Same field layout
	elif echo "$response" | grep -q '"CAT-NB"'; then
		mdd_parse_signal_lte "$response"
	elif echo "$response" | grep -q '"GSM"'; then
		mdd_parse_signal_gsm "$response"
	else
		echo "rat=unknown"
	fi
}

# Parse LTE serving cell response
mdd_parse_signal_lte() {
	local line
	line=$(echo "$1" | grep '+QENG:.*"servingcell"' | head -1)
	[ -z "$line" ] && line=$(echo "$1" | grep '+QENG:.*"LTE\|CAT-M\|CAT-NB"' | head -1)

	local state rat duplex mcc mnc cellid pcid earfcn band ul_bw dl_bw tac rsrp rsrq rssi sinr

	# Extract the RAT identifier
	rat=$(echo "$line" | grep -oE '"(LTE|CAT-M|CAT-NB)"' | tr -d '"')
	[ -z "$rat" ] && rat="LTE"

	state=$(echo "$line" | sed 's/.*"servingcell","//' | sed 's/".*//')

	# Parse CSV fields after the RAT field
	# Format: "servingcell","STATE","RAT","DUPLEX",MCC,MNC,CELLID,PCID,EARFCN,BAND,...,RSRP,RSRQ,RSSI,SINR,...
	local fields
	fields=$(echo "$line" | sed 's/+QENG: //' | tr -d '"' | tr ',' ' ')
	set -- $fields

	# Skip: servingcell state rat duplex
	shift 4 2>/dev/null
	mcc=$1; mnc=$2; cellid=$3; pcid=$4; earfcn=$5; band=$6
	shift 6 2>/dev/null
	# Skip: ul_bw dl_bw tac
	shift 3 2>/dev/null
	rsrp=$1; rsrq=$2; rssi=$3; sinr=$4

	echo "rat=$rat"
	echo "state=$state"
	echo "band=$band"
	echo "rsrp=$rsrp"
	echo "rsrq=$rsrq"
	echo "rssi=$rssi"
	echo "sinr=$sinr"
	echo "cellid=$cellid"
	echo "earfcn=$earfcn"
	echo "mcc=$mcc"
	echo "mnc=$mnc"
}

# Parse 5G NSA (dual-connectivity with LTE anchor)
mdd_parse_signal_nr5g_nsa() {
	# LTE anchor line (NSA format: +QENG: "LTE","FDD",MCC,MNC,... — no "servingcell","STATE" prefix)
	local full_response="$1"
	local lte_line
	lte_line=$(echo "$full_response" | grep '+QENG:.*"LTE"')
	if [ -n "$lte_line" ]; then
		# Parse LTE anchor directly (2 fewer leading fields than standalone LTE)
		local fields
		fields=$(echo "$lte_line" | sed 's/+QENG: //' | tr -d '"' | tr ',' ' ')
		set -- $fields
		# LTE,DUPLEX,MCC,MNC,CELLID,PCID,EARFCN,BAND,UL_BW,DL_BW,TAC,RSRP,RSRQ,RSSI,SINR,...
		shift 2 2>/dev/null  # skip LTE, DUPLEX
		local mcc=$1 mnc=$2 cellid=$3 pcid=$4 earfcn=$5 band=$6
		shift 6 2>/dev/null
		# Skip: ul_bw dl_bw tac
		shift 3 2>/dev/null
		local rsrp=$1 rsrq=$2 rssi=$3 sinr=$4

		# Get state from the first response line: +QENG: "servingcell","STATE"
		local state
		state=$(echo "$full_response" | grep '"servingcell"' | sed 's/.*"servingcell","//' | sed 's/".*//')

		echo "rat=LTE"
		echo "state=${state:-NOCONN}"
		echo "band=$band"
		echo "rsrp=$rsrp"
		echo "rsrq=$rsrq"
		echo "rssi=$rssi"
		echo "sinr=$sinr"
		echo "cellid=$cellid"
		echo "earfcn=$earfcn"
		echo "mcc=$mcc"
		echo "mnc=$mnc"
	fi

	# NR5G-NSA line
	local nr_line
	nr_line=$(echo "$full_response" | grep '+QENG:.*"NR5G-NSA"')
	if [ -n "$nr_line" ]; then
		local fields
		fields=$(echo "$nr_line" | sed 's/+QENG: //' | tr -d '"' | tr ',' ' ')
		set -- $fields
		# NR5G-NSA,MCC,MNC,PCID,RSRP,SINR,RSRQ,ARFCN,BAND,NR_DL_BW,SCS
		shift 1 2>/dev/null  # skip NR5G-NSA
		echo "nr_rat=NR5G-NSA"
		echo "nr_rsrp=$4"
		echo "nr_sinr=$5"
		echo "nr_rsrq=$6"
		echo "nr_arfcn=$7"
		echo "nr_band=$8"
	fi
}

# Parse 5G SA
mdd_parse_signal_nr5g_sa() {
	local line
	line=$(echo "$1" | grep '+QENG:.*"NR5G-SA"')
	local fields
	fields=$(echo "$line" | sed 's/+QENG: //' | tr -d '"' | tr ',' ' ')
	set -- $fields
	# servingcell,STATE,NR5G-SA,DUPLEX,MCC,MNC,CELLID,PCID,TAC,ARFCN,BAND,NR_DL_BW,RSRP,RSRQ,SINR,SCS,SRXLEV
	shift 3 2>/dev/null  # skip servingcell state NR5G-SA
	local duplex=$1; shift
	echo "rat=NR5G-SA"
	echo "state=$(echo "$line" | sed 's/.*"servingcell","//' | sed 's/".*//')"
	echo "mcc=$1"; shift
	echo "mnc=$1"; shift
	echo "cellid=$1"; shift
	shift 1  # pcid
	shift 1  # tac
	echo "earfcn=$1"; shift
	echo "band=$1"; shift
	shift 1  # nr_dl_bw
	echo "rsrp=$1"; shift
	echo "rsrq=$1"; shift
	echo "sinr=$1"
}

# Parse GSM (2G)
mdd_parse_signal_gsm() {
	echo "rat=GSM"
	echo "state=LIMSRV"
	echo "band=0"
	echo "rsrp=0"
	echo "rsrq=0"
	echo "sinr=0"
}

# --- Temperature ---

# Get modem temperature (max value as integer)
mdd_get_temp() {
	local response
	response=$(mdd_send_at "AT+QTEMP")

	if echo "$response" | grep -q '".*",".*"'; then
		# Modern format: +QTEMP: "sensor","value"
		local max=0
		local val
		echo "$response" | grep '+QTEMP:' | while read -r line; do
			val=$(echo "$line" | sed 's/.*","//' | tr -d '"' | tr -d ' ')
			val=$(echo "$val" | grep -oE '[0-9]+' | head -1)
			[ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null && [ "$val" -gt "$max" ] && max=$val
		done
		# Since while loop runs in subshell, re-parse
		echo "$response" | grep '+QTEMP:' | sed 's/.*","//' | tr -d '"' | tr -d ' ' |
			grep -oE '[0-9]+' | sort -rn | head -1
	else
		# Legacy format: +QTEMP: val1,val2,val3
		local vals
		vals=$(echo "$response" | grep '+QTEMP:' | sed 's/+QTEMP: *//' | tr ',' '\n' | grep -oE '[0-9]+')
		echo "$vals" | sort -rn | head -1
	fi
}

# --- Interface Detection ---

# Find the modem WAN interface name from UCI
mdd_detect_interface() {
	local iface=""

	# Check UCI network config for QMI/MBIM/QCM interfaces
	. /lib/functions.sh 2>/dev/null
	config_load network 2>/dev/null

	_check_modem_iface() {
		local cfg="$1"
		local proto device
		config_get proto "$cfg" proto ""
		config_get device "$cfg" device ""
		case "$proto" in
			qmi|mbim|qcm|ncm)
				iface="$cfg"
				;;
		esac
	}
	config_foreach _check_modem_iface interface

	if [ -n "$iface" ]; then
		echo "$iface"
	else
		# Fallback: look for common names
		for name in modem_1_1_2 wwan wan_m wan4g lte; do
			uci -q get "network.$name" >/dev/null 2>&1 && echo "$name" && return 0
		done
	fi
}

# Find the wwan network device (e.g., wwan0)
mdd_detect_wwan() {
	# Check for wwan devices
	for dev in wwan0 wwan1 usb0 eth1; do
		ip link show "$dev" >/dev/null 2>&1 && echo "$dev" && return 0
	done

	# Fallback: find device associated with the modem interface
	local iface
	iface=$(mdd_detect_interface)
	if [ -n "$iface" ]; then
		local l3dev
		l3dev=$(ifstatus "$iface" 2>/dev/null | grep '"l3_device"' | sed 's/.*: *"//' | tr -d '",' | tr -d ' ')
		[ -n "$l3dev" ] && echo "$l3dev" && return 0
		l3dev=$(ifstatus "$iface" 2>/dev/null | grep '"device"' | sed 's/.*: *"//' | tr -d '",' | tr -d ' ')
		[ -n "$l3dev" ] && echo "$l3dev" && return 0
	fi

	return 1
}

# --- Modem Control ---

# Force cell reselection via airplane mode toggle
mdd_airplane_toggle() {
	mdd_log "Toggling airplane mode for cell reselection"
	mdd_send_at "AT+CFUN=4" >/dev/null
	sleep 3
	mdd_send_at "AT+CFUN=1" >/dev/null
}

# Hard modem reset (full reboot)
mdd_hard_reset() {
	mdd_log "Performing hard modem reset (CFUN=1,1)"
	mdd_send_at "AT+CFUN=1,1" >/dev/null
}

# Disable modem sleep mode
mdd_disable_sleep() {
	mdd_send_at "AT+QSCLK=0" >/dev/null
}

# --- Initialization ---

# Initialize the library (call this first)
mdd_init() {
	mdd_detect_at_method
	mdd_detect_modem
}

# If called directly (not sourced), run detection and print info
if [ "$(basename "$0")" = "modem-doctor-lib.sh" ]; then
	case "${1:-detect}" in
		detect)
			mdd_init
			echo "AT method: $MDD_AT_METHOD"
			echo "AT port: ${MDD_AT_PORT:-N/A}"
			echo "Modem model: ${MDD_MODEM_MODEL:-unknown}"
			echo "Modem generation: ${MDD_MODEM_GEN:-unknown}"
			echo "Firmware: ${MDD_MODEM_FW:-unknown}"
			;;
		signal)
			mdd_init
			mdd_get_signal
			;;
		temp)
			mdd_init
			echo "Temperature: $(mdd_get_temp)C"
			;;
		*)
			echo "Usage: $0 {detect|signal|temp}"
			;;
	esac
fi
