'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var UPDATE_BIN  = '/usr/libexec/tailscale-update';
var LOG_FILE    = '/tmp/tailscale-update.log';
var RC_FILE     = '/tmp/tailscale-update.rc';

return view.extend({
	load: function () {
		return this.checkStatus();
	},

	checkStatus: function () {
		return fs.exec(UPDATE_BIN, [ '--check', '--json' ]).then(function (res) {
			var out = (res.stdout || '').trim();
			if (!out) {
				return { error: (res.stderr || '').trim() || _('没有输出') };
			}
			try {
				return JSON.parse(out);
			} catch (e) {
				return { error: out };
			}
		}).catch(function (e) {
			return { error: e.message || String(e) };
		});
	},

	call: function (args) {
		return fs.exec(UPDATE_BIN, args);
	},

	readLog: function () {
		return fs.read(LOG_FILE).catch(function () { return ''; });
	},

	readRc: function () {
		return fs.read(RC_FILE).catch(function () { return ''; });
	},

	setLog: function (text) {
		if (this.logEl) {
			this.logEl.textContent = text || '';
			this.logEl.scrollTop = this.logEl.scrollHeight;
		}
	},

	// Show a notification that auto-closes after `seconds`, counting down in
	// the text. seconds = 0 keeps it until the user dismisses it (used for
	// errors, which you usually want to read).
	notice: function (title, msg, type, seconds) {
		var body = E('p', {}, [ msg ]);
		var n = ui.addNotification(title, body, type);
		if (!seconds || seconds <= 0)
			return n;

		var remaining = seconds;
		body.textContent = msg + ' (' + remaining + ')';
		var timer = setInterval(function () {
			remaining--;
			if (remaining <= 0) {
				clearInterval(timer);
				try {
					if (n && typeof n.remove === 'function')
						n.remove();
					else if (n && n.parentNode)
						n.parentNode.removeChild(n);
				} catch (e) {}
				return;
			}
			body.textContent = msg + ' (' + remaining + ')';
		}, 1000);
		return n;
	},

	handleCheck: function (ev) {
		ev.preventDefault();
		var self = this;
		return this.checkStatus().then(function (st) {
			self.state = st;
			self.refreshView();
		});
	},

	handleUpdate: function (ev) {
		ev.preventDefault();
		var self = this;
		self.startErr = '';
		return fs.remove(RC_FILE).catch(function () {}).then(function () {
			return self.call([ '--start' ]);
		}).catch(function (e) {
			// rpcd's file exec replies only once the command's pipe closes; a
			// client-side timeout often just means the background job detached
			// cleanly. Keep the detail for diagnostics, but don't alarm the user.
			self.startErr = (e && (e.message || String(e))) || 'unknown';
			return null;
		}).then(function () {
			self.notice(null, _('更新已开始，正在读取进度…'), 'info', 10);
			self.startPolling();
		});
	},

	handleRollback: function (ev) {
		ev.preventDefault();
		var self = this;
		if (!confirm(_('确定回滚到上一个备份的 Tailscale 版本吗？')))
			return Promise.resolve();
		return this.call([ '--rollback' ]).then(function (res) {
			self.notice(null, (res.stdout || res.stderr || '').trim(), 'info', 10);
			return self.handleCheck(new Event('click'));
		});
	},

	startPolling: function () {
		var self = this;
		var ticks = 0;
		if (this.polling)
			return;
		this.polling = true;
		poll.add(function () {
			ticks++;
			return Promise.all([ self.readRc(), self.readLog() ]).then(function (r) {
				var rc = (r[0] || '').trim();
				var log = (r[1] || '');
				// If nothing showed up after ~15s, surface the start-request
				// detail so a real failure is visible instead of a silent hang.
				if (!log && ticks === 5)
					log = _('尚无日志输出。启动响应：%s').format(self.startErr || 'ok');
				self.setLog(log || _('（等待日志…）'));
				if (rc !== '') {
					poll.stop();
					self.polling = false;
					self.notice(null,
						rc === '0' ? _('Tailscale 更新完成。') : _('更新失败，请查看下方日志。'),
						rc === '0' ? 'info' : 'error', rc === '0' ? 10 : 0);
					self.handleCheck(new Event('click'));
				} else if (ticks > 600) {  /* ~30 min at 3s */
					poll.stop();
					self.polling = false;
					self.notice(null, _('更新似乎卡住了，请查看下方日志。'), 'warning', 0);
				}
			});
		}, 3);
		poll.start();
	},

	row: function (label, value) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
			E('td', { 'class': 'td left' }, [ value ])
		]);
	},

	refreshView: function () {
		var st = this.state || {};
		// Use the live element reference: during render() the view is not yet
		// attached to the document, so document.getElementById() would miss it.
		var node = this.stateEl || document.getElementById('ts-updater-state');
		if (!node)
			return;

		if (st.error) {
			node.innerHTML = '';
			node.appendChild(E('div', { 'class': 'alert-message warning' },
				[ _('读取状态失败：%s').format(st.error) ]));
			return;
		}

		var avail = st.update_available === true;
		node.innerHTML = '';
		node.appendChild(E('table', { 'class': 'table' }, [
			this.row(_('已安装版本'), st.installed || _('未安装')),
			this.row(_('最新稳定版'), st.latest || '?'),
			this.row(_('架构'), (st.arch || '?') + ' (' + (st.kernel || '?') + ')'),
			this.row(_('状态'), avail
				? E('span', { 'style': 'color:#c00;font-weight:bold' }, [ _('可更新') ])
				: E('span', { 'style': 'color:#080' }, [ _('已是最新') ]))
		]));
	},

	render: function (state) {
		this.state = state || { error: _('未知') };

		this.logEl = E('pre', {
			'id': 'ts-updater-log',
			'style': 'max-height:22em;overflow:auto;white-space:pre-wrap;background:#111;color:#ddd;padding:8px;border-radius:4px;font-size:12px;'
		}, [ _('（等待日志…）') ]);

		this.stateEl = E('div', { 'id': 'ts-updater-state', 'class': 'cbi-section' }, [ _('正在检查更新…') ]);

		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Tailscale 更新工具') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('iStore 商店安装的 Tailscale 被固件源冻结在 1.80.3-1。本工具只替换 tailscale/tailscaled 两个二进制为官方最新稳定版，保留启动脚本、UCI 配置与登录状态。')
			]),
			this.stateEl,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'handleUpdate') }, [ _('立即更新到最新版') ]),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck') }, [ _('检查更新') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.createHandlerFn(this, 'handleRollback') }, [ _('回滚') ])
			]),
			E('h3', {}, [ _('日志') ]),
			this.logEl
		]);

		this.refreshView();

		// "One-click" mode: iStore's app card opens this page with ?run=1,
		// so a single tap there starts the update straight away.
		if (/\brun=1\b/.test(window.location.search || '') &&
		    this.state && this.state.update_available === true) {
			this.handleUpdate(new Event('click'));
		}

		// If an update is already running (e.g. page reloaded), resume polling.
		this.readRc().then(function (rc) {
			if ((rc || '').trim() === '')
				return this.readLog().then(function (log) {
					if ((log || '').indexOf('running') !== -1 || (log || '').length)
						this.startPolling();
				}.bind(this));
		}.bind(this));

		return view;
	}
});
