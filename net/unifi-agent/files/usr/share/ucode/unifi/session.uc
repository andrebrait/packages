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

	for (let k in [ 'authkey', 'use_gcm', 'cfgversion', 'inform_url', 'mgmt_url', 'stp_priority' ])
		if (st[k] != null)
			keep[k] = st[k];

	let text = sprintf('%.J\n', keep);

	if (st._saved == text)
		return;

	util.mkdir_p(STATE_DIR);
	util.write_file(STATE, text, 0o600);
	st._saved = text;
}

export function forget() {
	unlink(STATE);
};

function handle_mgmt(st, text) {
	let m = util.parse_kv(text);

	if (m.authkey && match(m.authkey, /^[0-9a-fA-F]{32}$/))
		st.authkey = m.authkey;

	if (m.use_aes_gcm != null)
		st.use_gcm = (m.use_aes_gcm == 'true');

	if (m.mgmt_url)
		st.mgmt_url = m.mgmt_url;

	if (m.cfgversion)
		st.cfgversion = m.cfgversion;
}

function handle_system(st, profile, text, cfgversion) {
	util.mkdir_p(RUN_DIR);
	util.write_file(`${RUN_DIR}/system_cfg`, text, 0o600);

	let res = apply.apply(text, profile, { inform_url: st.inform_url ?? profile.inform_url, log });

	if (length(res.unhandled))
		util.write_file(`${RUN_DIR}/unhandled`, join('\n', res.unhandled) + '\n');

	if (res.rolled_back)
		log(`config ${cfgversion} rolled back; it stays acknowledged so the controller does not resend it`);
	else if (res.applied)
		log(`config ${cfgversion} applied`);
	else if (res.changed)
		log(`config ${cfgversion} planned only (apply is off)`);

	st.cfgversion = cfgversion;
}

// Handles one controller reply. Returns seconds until the next inform.
export function handle(st, profile, msg) {
	let t = msg?._type;

	if (t == 'noop')
		return +(msg.interval ?? profile.interval);

	if (t == 'setparam') {
		if (msg.mgmt_cfg)
			handle_mgmt(st, msg.mgmt_cfg);

		if (msg.system_cfg)
			handle_system(st, profile, msg.system_cfg, msg.cfgversion ?? st.cfgversion);
		else if (msg.cfgversion)
			st.cfgversion = msg.cfgversion;

		if (msg.blocked_sta != null)
			wifi.blocked(profile, msg.blocked_sta);

		return 1;
	}

	if (t == 'cmd') {
		let cmd = msg.cmd;

		if (cmd == 'set-adopt') {
			if (msg.key)
				st.authkey = msg.key;

			if (msg.uri)
				st.inform_url = msg.uri;
		}
		else if (cmd == 'set-locate' || cmd == 'unset-locate') {
			st.locating = (cmd == 'set-locate');
		}
		else if (wifi.command(profile, msg)) {
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
		forget();

		for (let k in keys(st))
			delete st[k];

		return 1;
	}

	log(`unknown reply ${t}`);
	return profile.interval;
};

// One inform round trip. Returns seconds until the next one.
export function step(st, profile) {
	let url = st.inform_url ?? profile.inform_url;

	// SSH adoption: the ubnt account exists only while pending.
	if (profile.ssh_port) {
		sshadopt.account(!st.authkey);

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

	let d = inform.decode(r.body, key);

	if (d.error && adopted) {
		// A controller that forgot this device answers with the default key.
		let d0 = inform.decode(r.body, inform.DEFAULT_KEY);

		if (!d0.error) {
			log('controller replied with the default key; device was removed, back to pending');
			forget();

			for (let k in keys(st))
				delete st[k];

			d = d0;
		}
	}

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

	while (true) {
		let next = step(st, profile);
		sleep(((next > 0) ? next : 1) * 1000);
	}
};
