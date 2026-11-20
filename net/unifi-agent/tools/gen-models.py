#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build files/usr/share/unifi-agent/models.json from unifi-emu's
model_profiles.json (https://github.com/jamesbraid/unifi-emu, MIT).

Usage: tools/gen-models.py <unifi-emu>/model_profiles.json > \
         files/usr/share/unifi-agent/models.json

Ports are run-length encoded as [media, count, poe_caps]; only switches
(usw) and access points (uap) are kept.
"""
import json
import sys

src = json.load(open(sys.argv[1]))
out = {"_source": "jamesbraid/unifi-emu model_profiles.json, controller "
                  + src["controller_version"] + " (MIT)"}

for m in sorted(src["models"], key=lambda m: m["model"]):
    if m["type"] not in ("usw", "uap"):
        continue
    runs = []
    for p in sorted(m["ports"], key=lambda p: p["port_idx"]):
        key = [p["media"], p.get("poe_caps", 0)]
        if runs and [runs[-1][0], runs[-1][2]] == key:
            runs[-1][1] += 1
        else:
            runs.append([p["media"], 1, key[1]])
    e = {"name": m["model_display"], "type": m["type"],
         "version": m["version"], "ports": runs}
    if m.get("radios"):
        e["radios"] = [{k: r[k] for k in ("radio", "ht", "nss", "min_txpower",
                                          "max_txpower", "radio_caps",
                                          "antenna_gain")}
                       for r in m["radios"]]
    out[m["model"]] = e

json.dump(out, sys.stdout, separators=(",", ":"), sort_keys=True)
sys.stdout.write("\n")
