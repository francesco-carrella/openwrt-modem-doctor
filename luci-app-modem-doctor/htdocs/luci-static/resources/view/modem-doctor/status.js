'use strict';
'require view';
'require poll';
'require rpc';
'require dom';

var callGetStatus = rpc.declare({
	object: 'luci.modem-doctor',
	method: 'get_status',
	expect: { }
});

var callGetLog = rpc.declare({
	object: 'luci.modem-doctor',
	method: 'get_log',
	params: ['lines'],
	expect: { log: [] }
});

function rsrpLabel(rsrp) {
	if (!rsrp || rsrp === 0) return 'N/A';
	if (rsrp >= -80) return rsrp + ' dBm (Excellent)';
	if (rsrp >= -90) return rsrp + ' dBm (Good)';
	if (rsrp >= -100) return rsrp + ' dBm (Fair)';
	return rsrp + ' dBm (Poor)';
}

function sinrLabel(sinr) {
	if (sinr === undefined || sinr === 0) return 'N/A';
	if (sinr >= 20) return sinr + ' dB (Excellent)';
	if (sinr >= 13) return sinr + ' dB (Good)';
	if (sinr >= 0) return sinr + ' dB (Fair)';
	return sinr + ' dB (Poor)';
}

function tempLabel(temp) {
	if (!temp || temp <= 0) return 'N/A';
	if (temp >= 80) return temp + '\u00b0C (Critical!)';
	if (temp >= 70) return temp + '\u00b0C (Warning)';
	return temp + '\u00b0C';
}

function stateLabel(state) {
	var map = {
		'NOCONN': 'Idle',
		'CONNECT': 'Connected',
		'LIMSRV': 'Limited Service',
		'SEARCH': 'Searching...'
	};
	return map[state] || state || 'Unknown';
}

function timeSince(timestamp) {
	if (!timestamp || timestamp === 0) return 'Never';
	var now = Math.floor(Date.now() / 1000);
	var diff = now - timestamp;
	if (diff < 60) return diff + 's ago';
	if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
	if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
	return Math.floor(diff / 86400) + 'd ago';
}

function actionLabel(action) {
	var map = {
		'none': 'None',
		'started': 'Service started',
		'ok': 'OK',
		'interface_restart': 'Interface restart',
		'airplane_toggle': 'Airplane mode toggle',
		'hard_reset': 'Hard modem reset',
		'cell_reselection': 'Cell reselection',
		'cell_reselection_done': 'Cell reselection complete',
		'recovery_complete': 'Recovery complete'
	};
	return map[action] || action || 'None';
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callGetStatus(), {}),
			L.resolveDefault(callGetLog(30), [])
		]);
	},

	render: function(data) {
		var status = data[0] || {};
		var logData = data[1] || [];

		var modem = status.modem || {};
		var signal = status.signal || {};
		var watchdog = status.watchdog || {};

		var statusTable = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, E('strong', {}, _('Modem Model'))),
				E('td', { 'class': 'td left', 'id': 'modem-model' },
					modem.model || 'Unknown')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Firmware'))),
				E('td', { 'class': 'td left', 'id': 'modem-fw' }, modem.firmware || 'Unknown')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Temperature'))),
				E('td', { 'class': 'td left', 'id': 'modem-temp' }, tempLabel(modem.temperature))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Connection State'))),
				E('td', { 'class': 'td left', 'id': 'signal-state' }, stateLabel(signal.state))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('RAT / Band'))),
				E('td', { 'class': 'td left', 'id': 'signal-rat-band' },
					(signal.rat || '?') + ' / Band ' + (signal.band || '?'))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('RSRP'))),
				E('td', { 'class': 'td left', 'id': 'signal-rsrp' }, rsrpLabel(signal.rsrp))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('RSRQ'))),
				E('td', { 'class': 'td left', 'id': 'signal-rsrq' },
					signal.rsrq ? signal.rsrq + ' dB' : 'N/A')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('SINR'))),
				E('td', { 'class': 'td left', 'id': 'signal-sinr' }, sinrLabel(signal.sinr))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Cell ID'))),
				E('td', { 'class': 'td left', 'id': 'signal-cellid' }, signal.cellid || 'N/A')
			])
		]);

		var watchdogTable = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, E('strong', {}, _('Service'))),
				E('td', { 'class': 'td left', 'id': 'wd-status' },
					watchdog.running ? _('Running') : (watchdog.enabled ? _('Stopped') : _('Disabled')))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Last Check'))),
				E('td', { 'class': 'td left', 'id': 'wd-last-check' },
					timeSince(watchdog.last_check))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Last Latency'))),
				E('td', { 'class': 'td left', 'id': 'wd-latency' },
					watchdog.last_avg_latency > 0 ? watchdog.last_avg_latency + ' ms' : 'N/A')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, E('strong', {}, _('Last Action'))),
				E('td', { 'class': 'td left', 'id': 'wd-action' },
					actionLabel(watchdog.last_action) +
					(watchdog.last_action_time > 0 ? ' (' + timeSince(watchdog.last_action_time) + ')' : ''))
			])
		]);

		var logEntries = (Array.isArray(logData) ? logData : []).join('\n') || _('No log entries');
		var logPre = E('pre', {
			'class': 'command-output',
			'id': 'modem-doctor-log',
			'style': 'max-height: 300px; overflow-y: auto; font-size: 11px;'
		}, logEntries);

		var view = E('div', {}, [
			E('h2', {}, _('Modem Doctor')),
			E('div', { 'class': 'cbi-map' }, [
				E('fieldset', { 'class': 'cbi-section' }, [
					E('legend', {}, _('Modem & Signal Status')),
					statusTable
				]),
				E('fieldset', { 'class': 'cbi-section' }, [
					E('legend', {}, _('Watchdog Status')),
					watchdogTable
				]),
				E('fieldset', { 'class': 'cbi-section' }, [
					E('legend', {}, _('Recent Log')),
					logPre
				])
			])
		]);

		// Set up polling
		poll.add(L.bind(function() {
			return Promise.all([
				L.resolveDefault(callGetStatus(), {}),
				L.resolveDefault(callGetLog(30), [])
			]).then(L.bind(function(results) {
				var s = results[0] || {};
				var l = results[1] || [];
				var m = s.modem || {};
				var sig = s.signal || {};
				var wd = s.watchdog || {};

				var el;

				el = document.getElementById('modem-model');
				if (el) el.textContent = m.model || 'Unknown';

				el = document.getElementById('modem-fw');
				if (el) el.textContent = m.firmware || 'Unknown';

				el = document.getElementById('modem-temp');
				if (el) el.textContent = tempLabel(m.temperature);

				el = document.getElementById('signal-state');
				if (el) el.textContent = stateLabel(sig.state);

				el = document.getElementById('signal-rat-band');
				if (el) el.textContent = (sig.rat || '?') + ' / Band ' + (sig.band || '?');

				el = document.getElementById('signal-rsrp');
				if (el) el.textContent = rsrpLabel(sig.rsrp);

				el = document.getElementById('signal-rsrq');
				if (el) el.textContent = sig.rsrq ? sig.rsrq + ' dB' : 'N/A';

				el = document.getElementById('signal-sinr');
				if (el) el.textContent = sinrLabel(sig.sinr);

				el = document.getElementById('signal-cellid');
				if (el) el.textContent = sig.cellid || 'N/A';

				el = document.getElementById('wd-status');
				if (el) el.textContent = wd.running ? _('Running') : (wd.enabled ? _('Stopped') : _('Disabled'));

				el = document.getElementById('wd-last-check');
				if (el) el.textContent = timeSince(wd.last_check);

				el = document.getElementById('wd-latency');
				if (el) el.textContent = wd.last_avg_latency > 0 ? wd.last_avg_latency + ' ms' : 'N/A';

				el = document.getElementById('wd-action');
				if (el) el.textContent = actionLabel(wd.last_action) +
					(wd.last_action_time > 0 ? ' (' + timeSince(wd.last_action_time) + ')' : '');

				el = document.getElementById('modem-doctor-log');
				if (el) el.textContent = (Array.isArray(l) ? l : []).join('\n') || _('No log entries');
			}, this));
		}, this), 10);

		return view;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
