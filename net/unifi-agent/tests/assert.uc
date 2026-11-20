// Minimal assertions for the agent's tests.
let failed = 0;

export function eq(got, want, what) {
	let g = sprintf('%J', got), w = sprintf('%J', want);

	if (g != w) {
		warn(`FAIL ${what}\n  got:  ${g}\n  want: ${w}\n`);
		failed++;
	}
};

export function ok(cond, what) {
	if (!cond) {
		warn(`FAIL ${what}\n`);
		failed++;
	}
};

export function done() {
	if (failed)
		exit(1);

	print('ok\n');
};
