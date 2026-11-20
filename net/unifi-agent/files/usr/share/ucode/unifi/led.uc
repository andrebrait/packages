// SPDX-License-Identifier: GPL-2.0-only
// "Locate": blink a status LED with the kernel timer trigger.

import { lsdir, readfile, writefile } from 'fs';

const LEDS = '/sys/class/leds';

let saved = null;	// { name, trigger } while blinking

// The LED to blink: the configured one, else the first status/system LED.
export function pick(name) {
	if (name)
		return name;

	for (let l in sort(lsdir(LEDS) ?? []))
		if (match(l, /(status|sys|power|run)/))
			return l;

	return null;
}

function current_trigger(name) {
	let m = match(readfile(`${LEDS}/${name}/trigger`) ?? '', /\[([^\]]+)\]/);
	return m ? m[1] : 'none';
}

export function locate(on, name) {
	name = pick(name);

	if (!name)
		return false;

	if (on && !saved) {
		saved = { name, trigger: current_trigger(name) };
		writefile(`${LEDS}/${name}/trigger`, 'timer');
		writefile(`${LEDS}/${name}/delay_on`, '100');
		writefile(`${LEDS}/${name}/delay_off`, '100');
	}
	else if (!on && saved) {
		writefile(`${LEDS}/${saved.name}/trigger`, saved.trigger);
		saved = null;
	}

	return true;
}
