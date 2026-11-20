// SPDX-License-Identifier: GPL-2.0-only
// The inform loop: adoption, keys, setparam, commands.

import { unlink } from 'fs';
import * as util from 'unifi.util';
import * as inform from 'unifi.inform';
import * as http from 'unifi.http';
import * as collect from 'unifi.collect';
import * as apply from 'unifi.apply';
import * as wifi from 'unifi.wifi';
import * as sshadopt from 'unifi.sshadopt';
import * as led from 'unifi.led';

export const STATE_DIR = '/etc/unifi-agent';
const STATE = STATE_DIR + '/state.json';
const RUN_DIR = '/tmp/unifi-agent';

function log(msg) {
	warn(`unifi-agent: ${msg}\n`);
}

// Persistent state: the authkey and what the controller told us. Written
// only when it changes, to spare the flash.
export function load_state() {
	return util.read_json(STATE) ?? {};
};

function save_state(st) {
	let keep = {};

	for (let k in [ 'authkey', 'use_gcm', 'cfgversion', 'inform_url', 'mgmt_url', 'blocked' ])
		if (st[k] != null)
			keep[k] = st[k];

	let text = sprintf('%.J\n', keep);

	if (st._saved == text)
		return;

	util.mkdir_p(STATE_DIR, 0o700);
	util.write_file(STATE, text, 0o600);
	st._saved = text;
}

// Drops the controller's key and everything it told us; st, when given,
// is cleared in place.
export function forget(st) {
	unlink(STATE);

	for (let k in keys(st ?? {}))
		delete st[k];
};

const KEY_RE = /^[0-9a-fA-F]{32}$/;


function handle_mgmt(st, text) {
	let m = util.parse_kv(text);

	if (m.authkey && match(m.authkey, KEY_RE))
		st.authkey = m.authkey;

	if (m.use_aes_gcm != null)
		st.use_gcm = (m.use_aes_gcm == 'true');

	if (m.mgmt_url)
		st.mgmt_url = m.mgmt_url;

	if (m.cfgversion)
		st.cfgversion = m.cfgversion;
}

// Applies a system_cfg. Returns false when it was deferred.
function handle_system(st, profile, text, cfgversion) {
	util.mkdir_p(RUN_DIR, 0o755);
	util.write_file(`${RUN_DIR}/system_cfg`, text, 0o600);

	// A deferred config comes back on every inform: say why only once.
	let quiet = (st._deferred == cfgversion);
	let res = apply.apply(text, profile, { inform_url: st.inform_url ?? profile.inform_url,
		log: quiet ? () => null : log });

	util.write_file(`${RUN_DIR}/unhandled`, length(res.unhandled) ? join('\n', res.unhandled) + '\n' : '');

	if (res.deferred || res.failed) {
		st._deferred = cfgversion;
		return false;	// not acknowledged: the controller sends it again
	}

	delete st._deferred;

	if (res.rolled_back)
		log(`config ${cfgversion} rolled back; it stays acknowledged so the controller does not resend it`);
	else if (res.applied)
		log(`config ${cfgversion} applied`);
	else if (res.changed)
		log(`config ${cfgversion} planned only (apply is off)`);

	st.cfgversion = cfgversion;
	return true;
}

// Handles one controller reply. Returns seconds until the next inform.
export function handle(st, profile, msg) {
	let t = msg?._type;

	if (t == 'noop')
		return +(msg.interval ?? profile.interval);

	if (t == 'setparam') {
		let acked = st.cfgversion;

		if (msg.mgmt_cfg)
			handle_mgmt(st, msg.mgmt_cfg);

		if (msg.system_cfg) {
			if (!handle_system(st, profile, msg.system_cfg, msg.cfgversion ?? st.cfgversion)) {
				// Keep reporting the old version, so the controller resends.
				st.cfgversion = acked;
				return profile.interval;
			}
		}
		else if (msg.cfgversion) {
			st.cfgversion = msg.cfgversion;
		}

		if (msg.blocked_sta != null)
			st.blocked = wifi.parse_blocked(msg.blocked_sta);

		return 1;
	}

	if (t == 'cmd') {
		let cmd = msg.cmd;

		if (cmd == 'set-adopt') {
			if (msg.key && match(msg.key, KEY_RE))
				st.authkey = lc(msg.key);
			else if (msg.key)
				log('ignoring set-adopt with a malformed key');

			if (msg.uri && util.inform_url_ok(msg.uri))
				st.inform_url = msg.uri;
			else if (msg.uri)
				log('ignoring set-adopt with an inform URL that is not http://<IP>[:port]/inform');
		}
		else if (cmd == 'set-locate' || cmd == 'unset-locate') {
			st.locating = (cmd == 'set-locate');

			if (!led.locate(st.locating, profile.locate_led))
				log('no LED to blink for locate');
		}
		else if (wifi.command(profile, msg, st)) {
			// handled by the wireless side
		}
		else {
			log(`ignoring command ${cmd}`);
		}

		return 1;
	}

	if (t == 'reboot') {
		log('reboot requested by the controller');
		system('reboot');
		return 60;
	}

	if (t == 'upgrade') {
		// Ubiquiti firmware would brick this device.
		log(`refusing firmware upgrade to ${msg.version}`);
		return profile.interval;
	}

	if (t == 'setdefault') {
		log('controller asked for factory defaults; forgetting the controller only');
		forget(st);

		return 1;
	}

	log(`unknown reply ${t}`);
	return profile.interval;
};

// One inform round trip. Returns seconds until the next one.
export function step(st, profile) {
	let url = st.inform_url ?? profile.inform_url;

	// SSH adoption: the ubnt account exists only while pending and enabled.
	sshadopt.account(!!profile.ssh_port && !st.authkey);

	if (profile.ssh_port) {
		for (let r in sshadopt.take()) {
			if (st.authkey) {
				log('ignoring an SSH adoption request: already adopted');
				continue;
			}

			st.inform_url = r.url;
			url = r.url;

			if (r.key) {
				st.authkey = r.key;
				log(`adopted over SSH, informing ${r.url}`);
			}
			else {
				log(`inform URL set over SSH: ${r.url}`);
			}
		}
	}

	if (!url) {
		log('no inform_url configured');
		return 60;
	}

	let adopted = !!st.authkey;
	let key = st.authkey ?? inform.DEFAULT_KEY;
	let gcm = adopted && !!st.use_gcm;
	let payload = collect.inform(profile, { ...st, inform_url: url },
		(profile.ssh_port && !adopted) ? { sshd_port: profile.ssh_port } : null);
	let pkt = inform.encode(payload.mac, key, gcm, sprintf('%J', payload));

	if (pkt == null) {
		log('stored authkey is unusable; run "unifi-agent forget" to adopt again');
		return 60;
	}

	let r = http.post(url, pkt);

	if (r.error) {
		log(r.error);
		return profile.interval;
	}

	if (r.status == 404)
		return profile.interval;	// pending adoption, or not known yet

	if (r.status != 200) {
		log(`HTTP ${r.status} from ${url}`);
		return profile.interval;
	}

	// Only encrypted replies count, and only GCM once it was negotiated:
	// anyone on the path can answer a plain-HTTP inform.
	let d = inform.decode(r.body, key, gcm);

	if (d.error && adopted && !inform.decode(r.body, inform.DEFAULT_KEY, false).error)
		d.error = 'reply uses the factory key; if the device was removed from the controller, run "unifi-agent forget"';

	if (d.error) {
		log(`reply: ${d.error}`);
		return profile.interval;
	}

	let msg;

	try {
		msg = json(d.data);
	}
	catch (e) {
		log('reply is not JSON');
		return profile.interval;
	}

	let next = handle(st, profile, msg);
	save_state(st);

	return next;
};

export function run(profile) {
	let st = load_state();
	st._saved = sprintf('%.J\n', st);

	log(`running as ${profile.model} (${profile.model_display}), ${length(profile.ports)} ports, ${length(profile.radios)} radios`);

	// procd stops the agent with SIGTERM: never leave the adoption account,
	// and never stop between applying a config and its reachability check,
	// which is the only chance to roll it back.
	let busy = false, stopping = false;
	let stop = () => {
		sshadopt.account(false);
		exit(0);
	};

	signal('TERM', () => {
		if (busy)
			stopping = true;
		else
			stop();
	});

	while (true) {
		busy = true;

		let next = step(st, profile);

		busy = false;

		if (stopping)
			stop();

		if (!(next >= 1))
			next = 1;

		// Renewed every round, reply or not.
		wifi.enforce_blocked(profile, st.blocked);
		sleep(next * 1000);
	}
};
