// SPDX-License-Identifier: GPL-2.0-only
// Text front panel of the device as the controller sees it.

import * as profile_mod from 'unifi.profile';

const BAND_NAMES = { ng: '2.4 GHz', na: '5 GHz', '6e': '6 GHz' };

function speed_label(mbit) {
	if (!mbit)
		return '-';

	return (mbit >= 1000) ? `${mbit / 1000}G` : `${mbit}M`;
}

function pad(s, n) {
	s = `${s ?? ''}`;

	if (length(s) > n)
		return substr(s, 0, n);

	while (length(s) < n)
		s += ' ';

	return s;
}

// The profile as a plain object, for `show --json` and the LuCI page.
export function describe(p, st) {
	let by_idx = {};

	for (let x in p.ports)
		by_idx[x.idx] = x;

	return {
		model: p.model,
		model_display: p.model_display,
		type: p.type,
		inform_url: st?.inform_url ?? p.inform_url,
		adopted: !!st?.authkey,
		gcm: !!st?.use_gcm,
		apply: p.apply,
		apply_cats: keys(p.apply_cats ?? {}),
		ports: map(p.model_ports, (mp) => {
			let l = by_idx[mp.idx];

			return {
				idx: mp.idx,
				media: mp.media,
				model_poe: !!mp.poe_caps,
				device: l?.dev,
				local_media: l?.media,
				speeds: l?.speeds ?? [],
				max_speed: l?.max_speed ?? 0,
				poe: !!l?.poe
			};
		}),
		radios: map(p.radios, (r) => ({ name: r.name, band: r.radio, device: r.device, nss: r.nss, ht: r.ht })),
		unmapped_ports: map(p.unmapped, (x) => x.dev),
		unmapped_radios: map(p.unmapped_radios, (x) => x.device),
		candidates: p.candidates
	};
};

export function render(p, st) {
	let d = describe(p, st);
	let out = [];
	let W = 6;

	push(out, `${d.model_display} (${d.model}), ${d.type == 'uap' ? 'access point' : 'switch'}`);
	push(out, `controller: ${d.inform_url ?? 'not set'}   ${d.adopted ? 'adopted' + (d.gcm ? ', AES-GCM' : '') : 'not adopted'}   apply: ${!d.apply ? 'log only' : ((length(d.apply_cats) >= length(profile_mod.CATEGORIES)) ? 'all' : join(', ', d.apply_cats))}`);
	push(out, '');

	// Group ports into copper and fibre blocks, as on a front panel.
	let groups = [];

	for (let x in d.ports) {
		let fib = profile_mod.is_fiber(x.media);

		if (!length(groups) || groups[-1].fiber != fib)
			push(groups, { fiber: fib, ports: [] });

		push(groups[-1].ports, x);
	}

	let rows = [
		[ 'UniFi port', (x) => x.idx ],
		[ 'media', (x) => x.media ],
		[ 'local port', (x) => x.device ?? '-' ],
		[ 'max speed', (x) => x.device ? speed_label(x.max_speed) : '' ],
		[ 'PoE', (x) => x.poe ? 'yes' : (x.model_poe ? 'off' : '-') ]
	];

	let border = (l, m, r) => {
		let s = pad('', 12);

		for (let gi, g in groups) {
			s += l;

			for (let i, x in g.ports)
				s += '──────' + ((i < length(g.ports) - 1) ? m : r);

			s += ' ';
		}

		return s;
	};

	push(out, border('┌', '┬', '┐'));

	for (let row in rows) {
		let s = pad(row[0], 12);

		for (let g in groups) {
			s += '│';

			for (let x in g.ports)
				s += pad(' ' + row[1](x), W) + '│';

			s += ' ';
		}

		push(out, s);
	}

	push(out, border('└', '┴', '┘'));

	if (length(d.radios)) {
		push(out, '');

		for (let r in d.radios)
			push(out, `radio ${r.name}: ${BAND_NAMES[r.band] ?? r.band}, ${r.nss ?? '?'}x${r.nss ?? '?'} streams -> ${r.device}`);
	}

	if (length(d.unmapped_ports))
		push(out, `\nnot reported (no free UniFi port): ${join(', ', d.unmapped_ports)}`);

	if (length(d.unmapped_radios))
		push(out, `not reported (model has no such radio): ${join(', ', d.unmapped_radios)}`);

	if (length(d.candidates))
		push(out, `\nmodels that fit this hardware: ${join(', ', d.candidates)}`);

	return join('\n', out) + '\n';
};
