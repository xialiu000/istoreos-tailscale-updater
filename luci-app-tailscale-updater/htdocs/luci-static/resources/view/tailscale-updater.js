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
		if (this.busy)
			return Promise.resolve();
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
		if (this.busy || this.polling) {
			this.notice(null, _('更新正在进行，完成后再回滚。'), 'warning', 8);
			return Promise.resolve();
		}
		var msg = _('确定回滚到上一个备份的 Tailscale 版本吗？');
		if (!confirm(msg))
			return Promise.resolve();
		return this.call([ '--rollback' ]).then(function (res) {
			self.notice(null, _('回滚完成，正在刷新状态…'), 'info', 10);
			return self.handleCheck(new Event('click'));
		}).catch(function (e) {
			self.notice(null, _('回滚失败：%s').format(e.message || e), 'error', 0);
		});
	},

	setBusy: function (b) {
		this.busy = b;
		if (this.updateBtn) this.updateBtn.disabled = b;
		if (this.checkBtn) this.checkBtn.disabled = b;
		if (this.rollbackBtn)
			this.rollbackBtn.disabled = b || !(this.state && this.state.can_rollback === true);
	},

	startPolling: function () {
		var self = this;
		var ticks = 0;
		if (this.polling)
			return;
		this.polling = true;
		this.setBusy(true);
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
					self.setBusy(false);
					self.notice(null,
						rc === '0' ? _('Tailscale 更新完成。') : _('更新失败，请查看下方日志。'),
						rc === '0' ? 'info' : 'error', rc === '0' ? 10 : 0);
					self.handleCheck(new Event('click'));
				} else if (ticks > 600) {  /* ~30 min at 3s */
					poll.stop();
					self.polling = false;
					self.setBusy(false);
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
		var candOlder = st.candidate_is_older === true;
		node.innerHTML = '';
		node.appendChild(E('table', { 'class': 'table' }, [
			this.row(_('已安装版本'), st.installed || _('未安装')),
			this.row(_('升级方式'), st.mode === 'pkg'
				? _('软件包管理（社区版）')
				: (st.mode === 'official'
					? _('官方静态包（社区版安装，软件包已锁定）')
					: _('静态二进制（旧版 1.80.3-1）'))),
			this.row(st.mode === 'pkg'
				? (candOlder ? _('软件源候选（低于已装）') : _('软件源候选'))
				: _('最新稳定版'),
				(st.mode === 'pkg' ? (st.candidate || st.latest) : st.latest) || '?'),
			this.row(_('架构'), (st.arch || '?') + ' (' + (st.kernel || '?') + ')'),
			this.row(_('状态'), avail
				? E('span', { 'style': 'color:#c00;font-weight:bold' }, [ _('可更新') ])
				: E('span', { 'style': 'color:#080' }, [
					candOlder ? _('源内无更高版本') : _('已是最新')
				])),
			this.row(_('定时任务'), st.cron_installed === true
				? _('已启用（每天 %s）').format(st.auto_update_time || '?')
				: _('未启用')),
			this.row(_('可回滚到'), st.can_rollback === true
				? (st.rollback_version || '?')
				: _('无可回滚备份'))
		]));

		if (this.updateBtn && !this.busy)
			this.updateBtn.disabled = false;
		if (this.rollbackBtn) {
			this.rollbackBtn.disabled = this.busy || !(st.can_rollback === true);
			this.rollbackBtn.title = st.can_rollback === true
				? _('回滚到 %s').format(st.rollback_version || '?')
				: _('没有更早的备份可回滚');
		}

		if (st.mode === 'pkg' && candOlder)
			node.appendChild(E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:6px;color:#a60' }, [
				_('当前软件源里最高只有 %s，低于已装的 %s；要升级到更新的版本，需要先添加社区软件源。')
					.format(st.candidate || '?', st.installed || '?')
			]));

		if (this.sourceEl) {
			this.sourceEl.innerHTML = '';
			this.sourceEl.appendChild(this.sourceSection());
		}
		if (this.autoEl) {
			this.autoEl.innerHTML = '';
			this.autoEl.appendChild(this.autoSection());
		}
	},

	sourceSection: function () {
		var st = this.state || {};
		if (st.mode !== 'pkg' && st.mode !== 'official')
			return E('div');
		var self = this;
		var sel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'feed' }, [ _('社区软件包（跟随软件源）') ]),
			E('option', { 'value': 'official' }, [ _('官方 Tailscale 静态包') ])
		]);
		sel.value = st.update_source === 'official' ? 'official' : 'feed';
		sel.addEventListener('change', function () { self.handleSource(sel.value); });
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('更新来源') ]),
			E('div', { 'class': 'cbi-value-field' }, [
				sel,
				E('div', { 'class': 'cbi-value-description' }, [
					_('社区安装默认跟随社区软件源；选“官方静态包”会用 Tailscale 官方源的最新二进制替换，并锁定 tailscale 软件包（不再随软件包管理器升级）。')
				])
			])
		]);
	},

	handleSource: function (src) {
		var self = this;
		return this.call([ '--set-source', src ]).then(function (res) {
			self.notice(null, _('更新来源已保存'), 'info', 5);
			return self.handleCheck(new Event('click'));
		}).catch(function (e) {
			self.notice(null, _('保存失败：%s').format(e.message || e), 'error', 0);
		});
	},

	autoSection: function () {
		var st = this.state || {};
		var self = this;
		var cb = E('input', { 'type': 'checkbox' });
		cb.checked = st.auto_update === true;
		var timeEl = E('input', { 'type': 'time' });
		timeEl.value = st.auto_update_time || '03:00';

		cb.addEventListener('change', function () {
			self.handleAuto(cb.checked, timeEl.value);
		});
		timeEl.addEventListener('change', function () {
			if (cb.checked)
				self.handleAuto(true, timeEl.value);
		});

		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ _('自动更新') ]),
			E('div', { 'class': 'cbi-value-field' }, [
				cb, ' ', timeEl,
				E('div', { 'class': 'cbi-value-description' }, [
					_('每天在设定时间检查一次，只有发现新版本时才更新；旧版与社区版都适用。关闭时会移除 /etc/crontabs/root 中的定时任务。')
				])
			])
		]);
	},

	handleAuto: function (enabled, time) {
		var self = this;
		return this.call([ '--set-auto', enabled ? '1' : '0', time || '03:00' ]).then(function (res) {
			self.notice(null, _('自动更新设置已保存'), 'info', 5);
			return self.handleCheck(new Event('click'));
		}).catch(function (e) {
			self.notice(null, _('保存失败：%s').format(e.message || e), 'error', 0);
		});
	},

	render: function (state) {
		this.state = state || { error: _('未知') };

		this.logEl = E('pre', {
			'id': 'ts-updater-log',
			'style': 'max-height:22em;overflow:auto;white-space:pre-wrap;background:#111;color:#ddd;padding:8px;border-radius:4px;font-size:12px;'
		}, [ _('（等待日志…）') ]);

		this.stateEl = E('div', { 'id': 'ts-updater-state', 'class': 'cbi-section' }, [ _('正在检查更新…') ]);

		this.updateBtn = E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'handleUpdate') }, [ _('立即更新到最新版') ]);
		this.checkBtn = E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck') }, [ _('检查更新') ]);
		this.rollbackBtn = E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.createHandlerFn(this, 'handleRollback') }, [ _('回滚') ]);

		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Tailscale 更新工具') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('自动识别安装方式：商店旧版 Tailscale（冻结在 1.80.3-1）替换为官方静态二进制；「Tailscale（社区版）」默认通过软件包管理器升级，也可在下方切换为官方静态包。两者都保留启动脚本、UCI 配置与登录状态。')
			]),
			this.stateEl,
			this.sourceEl = this.sourceSection(),
			this.autoEl = this.autoSection(),
			E('div', { 'class': 'cbi-page-actions' }, [
				this.updateBtn,
				' ',
				this.checkBtn,
				' ',
				this.rollbackBtn
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
