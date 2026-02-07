'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('modem-doctor');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('modem-doctor', _('Modem Doctor Configuration'),
			_('Modem Doctor monitors your cellular connection and automatically ' +
			  'recovers from high latency or connection drops.'));

		// --- General Section ---
		s = m.section(form.NamedSection, 'main', 'modem-doctor', _('General'));

		o = s.option(form.Flag, 'enabled', _('Enable Modem Doctor'),
			_('Start the watchdog service and apply modem tweaks'));
		o.rmempty = false;
		o.default = '0';

		// --- Interface Section ---
		s = m.section(form.NamedSection, 'interface', 'interface', _('Interface'));
		s.description = _('How to find your modem. Auto-detect works for most setups.');

		o = s.option(form.Flag, 'auto_detect', _('Auto-detect interface'),
			_('Automatically find the modem WAN interface and wwan device'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'iface_name', _('Interface name'),
			_('UCI interface name (e.g., modem_1_1_2, wwan, wan)'));
		o.placeholder = 'auto';
		o.depends('auto_detect', '0');
		o.optional = true;

		o = s.option(form.Value, 'wwan_device', _('WWAN device'),
			_('Network device name (e.g., wwan0, usb0)'));
		o.placeholder = 'auto';
		o.depends('auto_detect', '0');
		o.optional = true;

		// --- Watchdog Section ---
		s = m.section(form.NamedSection, 'watchdog', 'watchdog', _('Watchdog'));
		s.description = _('Monitors connectivity and latency. If the connection drops, ' +
			'it restarts the modem interface, then toggles airplane mode, escalating ' +
			'until connectivity is restored. If latency is too high, it forces a cell ' +
			'reselection to find a better tower.');

		o = s.option(form.Value, 'ping_target', _('Ping target'),
			_('IP address or hostname to check connectivity'));
		o.datatype = 'host';
		o.default = '1.1.1.1';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Check interval (seconds)'),
			_('How often to check connectivity and latency'));
		o.datatype = 'and(uinteger,min(30))';
		o.default = '120';
		o.rmempty = false;

		o = s.option(form.Value, 'latency_threshold', _('Latency threshold (ms)'),
			_('Average ping above this triggers cell reselection'));
		o.datatype = 'and(uinteger,min(50))';
		o.default = '500';
		o.rmempty = false;

		o = s.option(form.Value, 'ping_count', _('Connectivity ping count'),
			_('Number of pings for connectivity check (all must fail to trigger recovery)'));
		o.datatype = 'and(uinteger,range(1,10))';
		o.default = '3';

		o = s.option(form.Value, 'latency_pings', _('Latency ping count'),
			_('Number of pings used to calculate average latency. ' +
			  'More pings = more accurate but takes longer per check.'));
		o.datatype = 'and(uinteger,range(1,50))';
		o.default = '20';

		o = s.option(form.Value, 'ping_timeout', _('Ping timeout (seconds)'),
			_('Timeout for each individual ping'));
		o.datatype = 'and(uinteger,range(1,30))';
		o.default = '5';

		o = s.option(form.Value, 'recovery_wait', _('Recovery wait (seconds)'),
			_('Time to wait after interface restart before checking again'));
		o.datatype = 'and(uinteger,min(5))';
		o.default = '15';

		// --- SQM/CAKE Section ---
		s = m.section(form.NamedSection, 'sqm', 'sqm', _('Traffic Shaping (SQM/CAKE)'));
		s.description = _('CAKE is a smart queue that prevents bufferbloat — the main cause of ' +
			'latency spikes under load. Set bandwidth below your actual connection speed ' +
			'so CAKE can manage the queue instead of letting the modem buffer packets.');

		o = s.option(form.Flag, 'disable_sfe', _('Disable hardware offloading (SFE)'),
			_('Hardware offloading (SFE) speeds up routing but completely bypasses CAKE, ' +
			  'making traffic shaping ineffective. Must be disabled for CAKE to work. ' +
			  'May slightly reduce maximum throughput.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'configure_sqm', _('Enable SQM management'),
			_('Let Modem Doctor configure and manage SQM/CAKE on the modem interface. ' +
			  'Disable this if you want to manage SQM settings manually.'));
		o.rmempty = false;
		o.default = '1';
		o.depends('disable_sfe', '1');

		o = s.option(form.Value, 'download', _('Download limit (kbps)'),
			_('Must be below your actual download speed for CAKE to work. ' +
			  'Recommended: 80% of measured speed. ' +
			  'Example: 60 Mbps connection = 48000 kbps.'));
		o.datatype = 'and(uinteger,min(1000))';
		o.default = '48000';
		o.rmempty = false;
		o.depends('configure_sqm', '1');

		o = s.option(form.Value, 'upload', _('Upload limit (kbps)'),
			_('Must be below your actual upload speed for CAKE to work. ' +
			  'Recommended: 80% of measured speed. ' +
			  'Example: 30 Mbps connection = 24000 kbps.'));
		o.datatype = 'and(uinteger,min(500))';
		o.default = '24000';
		o.rmempty = false;
		o.depends('configure_sqm', '1');

		// --- Modem Tweaks Section ---
		s = m.section(form.NamedSection, 'fixes', 'fixes', _('Modem Tweaks'));
		s.description = _('Low-level fixes applied once when the service starts. ' +
			'The defaults work well for most Quectel modems. ' +
			'Only change these if you know what you are doing.');

		o = s.option(form.Value, 'txqueuelen', _('TX queue length'),
			_('Transmit queue size on the modem device. ' +
			  'Lower values reduce bufferbloat. Stock OpenWrt default is 1000.'));
		o.datatype = 'and(uinteger,range(10,1000))';
		o.default = '100';
		o.rmempty = false;

		o = s.option(form.Flag, 'disable_gro', _('Disable GRO'),
			_('Generic Receive Offload batches incoming packets together, ' +
			  'which improves throughput but can cause latency spikes.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'disable_modem_sleep', _('Disable modem sleep'),
			_('Modem sleep saves power but causes latency spikes when waking up. ' +
			  'Sends AT+QSCLK=0 to the modem at startup.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'tcp_no_slow_start', _('Disable TCP slow start after idle'),
			_('Prevent TCP from resetting its speed after idle periods. ' +
			  'Recommended for cellular connections where idle gaps are common.'));
		o.default = '1';
		o.rmempty = false;

		return m.render();
	}
});
