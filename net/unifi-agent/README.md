# unifi-agent

Lets a UniFi Network controller adopt an OpenWrt device as a UniFi switch or access point, apply its settings, and show its status. The agent is written in ucode, plus a small C module for AES. The package is about 35 KB (122 KB installed, most of it the model catalog), so it fits devices with 16 MiB of flash.

The agent speaks the UniFi inform protocol. Before a device is adopted it uses the factory key; after adoption it uses the key the controller assigns, with AES-GCM once the controller asks for it. Firmware upgrades from the controller are always refused, because Ubiquiti firmware would brick the device. After a refusal the agent reports the offered version as its own, so the controller stops offering it; to have the controller offer it again, run `unifi-agent forget` (or edit `/etc/unifi-agent/state.json`).

## Setup

1. Check what the controller will see:

   ```sh
   unifi-agent show
   ```

   ```
   UniFi Switch 6 XG PoE (US6XG150), switch
   controller: not set   not adopted   apply: on

               ┌──────┬──────┬──────┬──────┐ ┌──────┬──────┐
   UniFi port  │ 1    │ 2    │ 3    │ 4    │ │ 5    │ 6    │
   media       │ GE   │ GE   │ GE   │ GE   │ │ SFP+ │ SFP+ │
   local port  │ lan1 │ lan2 │ lan3 │ lan4 │ │ lan5 │ lan6 │
   max speed   │ 10G  │ 10G  │ 10G  │ 10G  │ │ 10G  │ 10G  │
   PoE         │ off  │ off  │ off  │ off  │ │ -    │ -    │
               └──────┴──────┴──────┴──────┘ └──────┴──────┘

   models that fit this hardware: US6XG150, USLP8P, USWED76, USWED77, USXG
   ```

2. Enable the agent and point it at the controller:

   ```sh
   uci set unifi-agent.main.inform_url='http://192.168.1.2:8080/inform'
   uci set unifi-agent.main.enabled='1'
   uci commit unifi-agent
   /etc/init.d/unifi-agent enable
   /etc/init.d/unifi-agent start
   ```

   A controller on the device's own subnet adopts over SSH instead of using the inform URL. That needs `option ssh_adopt '1'` while the device is being adopted (see [SSH adoption](#ssh-adoption)).
3. In the controller, adopt the device. It appears as pending, under the chosen model's name.
4. Watch the log with `logread -e unifi-agent`. Every change the controller asks for is logged as a plan line before it is applied.

To stage a rollout, set `option apply '0'`: the agent then only logs what it would change. `unifi-agent plan <file>` translates a saved `system_cfg` without changing anything. The last one received is kept in `/tmp/unifi-agent/system_cfg`.

LuCI users get the same front panel and every setting under Services → UniFi controller (`luci-app-unifi-agent`).

## Choosing what the controller sees

The controller decides which settings to offer from the model's port layout. A model whose layout matches the hardware gives the best result.

- `option model 'auto'` (the default) picks the closest catalog model:
  - for a switch, the same copper and fibre port counts, or else the smallest model with room for both, preferring a model without PoE;
  - for an access point, the same radio bands.
- `option model '<id>'` forces a model. `unifi-agent models [text]` lists the catalog: 174 UniFi switches and access points, generated from [unifi-emu](https://github.com/jamesbraid/unifi-emu)'s model profiles.
- `config port` sections map UniFi ports to local ports. Without them, every port of the bridge is mapped in natural order, copper to copper and fibre to fibre:

  ```
  config port
  	option unifi '5'        # UniFi port number
  	option device 'lan5'
  	option media 'SFP+'     # GE, SFP, SFP+, SFP28; detected when unset
  	option poe '0'          # 1: report PoE and switch it through netifd's pse option
  ```

  Fibre is detected from the port's `sfp` device-tree link or from ethtool. The speeds offered for each port come from ethtool's supported link modes.
- `config radio` sections map UniFi radios to `wifi-device` sections. Without them, every enabled radio is used, with its band taken from UCI.

A model with more ports than the device works: the extra UniFi ports are simply not reported. PoE is never reported unless a port has `option poe '1'`, so the controller hides PoE controls on a device without it. This holds even for a PoE model.

## What the controller can configure

| Controller setting | Applied as |
|---|---|
| Networks on ports (native VLAN, tagged VLANs, "block all") | `bridge-vlan` sections on the bridge, with `vlan_filtering`; the management interface moves to `<bridge>.<mgmt vlan>` |
| Port disable, speed and duplex, flow control, EEE, isolation | netifd device options `enabled`, `autoneg`, `speed`, `duplex`, `pause`, `eee`, `isolate` |
| Link aggregation (UniFi uses LACP only) | a netifd `bonding` device `lagN`, mode 802.3ad, replacing its members in the bridge |
| Jumbo frames | `mtu` on the ports and the bridge |
| Spanning tree (STP or RSTP, bridge priority) | bridge `stp`, `stp_proto`, `priority` (RSTP needs `ustp`) |
| IGMP snooping, querier, fast leave | bridge `igmp_snooping`, `bridge-vlan` `mcast_snooping` and `mcast_querier`, device `multicast_fast_leave` |
| Port mirroring, egress rate limit | `switchdev-config` sections, when that package is installed |
| PoE mode | device `pse`, only on ports marked `poe` |
| Radios: channel, width, power, country, outdoor | `wifi-device` `channel`, `htmode`, `txpower`, `country`, `country3` |
| WLANs: SSID, WPA2, WPA3, PMF, hidden, client isolation, MAC filter, VLAN, 802.11r/k/v | `wifi-iface` sections; a WLAN on a VLAN gets an unaddressed network over that VLAN |

After a commit the agent reloads the network (and Wi-Fi), then checks that the controller can still be reached. If it can't within a minute, the previous configuration is restored. The backup is kept in memory: a reboot inside that minute keeps the new configuration. If the management VLAN is not among the controller's VLANs, the VLAN settings are left unchanged, so the device stays reachable. WLANs the controller no longer lists are disabled, never deleted.

Changes staged with the `uci` command but not committed are never committed with the controller's: while there are any for `network`, `wireless` or `switchdev`, the agent waits, logs why, and leaves the controller's configuration unacknowledged, so the controller sends it again. LuCI keeps its staged changes apart, so they do not count. The check runs again just before committing, but a `uci set` that lands in the instant between that check and the commit is committed with the controller's settings: libuci offers no way to commit without loading the CLI's changes.

Settings the agent does not carry out are not claimed in the device's capabilities, so the controller does not offer them. Settings it receives but does not apply are listed in `/tmp/unifi-agent/unhandled`. Examples: storm control, per-port STP edge or BPDU guard, 802.1X, port security, and on access points WLAN schedules, rate limits and the guest portal.

Every device reports, every 10 s, to the controller:
- per port: link state, speed, duplex, byte, packet and error counters, STP state, learned MAC addresses, LLDP neighbours (with `lldpd`), and SFP module data and diagnostics;
- CPU, memory, load and temperature.

Access points also report radios, WLANs and clients with signal, rates and traffic.

## SSH adoption

A controller adopts a device on its own subnet by logging in over SSH as `ubnt` with password `ubnt`, the factory login of a UniFi device, and running `set-adopt`. A device it reaches only through a router is adopted with the inform URL instead. With `option ssh_adopt '1'`, while the device is not adopted, the agent provides that login:

- a `ubnt` account, whose login shell is `/usr/libexec/unifi-agent/ssh-adopt`. That handler records `set-adopt` and `set-inform` requests and does nothing else.
- a dropbear instance on `ssh_port` (default 2222, reported to the controller), which runs only that handler for every login, refuses root password logins, and allows no port forwarding (`-j -k`).

The agent accepts a request only while it is pending, and only with an IP-literal inform URL and a 32-digit key. It removes the account once adopted, when SSH adoption or the agent is turned off, when the service stops (including at shutdown), and when the package is removed. One case is left to you: if the service is disabled while a device is pending with SSH adoption on, run `unifi-agent cleanup`. An existing `ubnt` account that the agent did not create is never touched.

It is off by default, and is best turned on only for the adoption itself, for two reasons:

- Anyone on the network can adopt a pending device into their own controller, as with a factory-default UniFi device.
- If the system dropbear on port 22 accepts passwords (OpenWrt's default), `ubnt`/`ubnt` can log in there too while the device is pending. The handler keeps that login from running commands, but dropbear has no per-user switch for TCP forwarding, so the login can still forward connections through the device.

## Removing a device

After the device is forgotten in the controller, run `unifi-agent forget` on the device to make it pending again; the applied configuration stays. The agent does not do this on its own when the controller answers with the factory key: the inform protocol runs over plain HTTP, so such a reply is not proof that it comes from the controller. For the same reason, replies that are not encrypted are ignored, and once AES-GCM is in use, so are CBC replies.

## Credits

- The access point translation follows [unifi-openwrt](https://github.com/antoniocosta/unifi-openwrt) (GPL-2.0-or-later), which tested it on real access points against UniFi Network 10.6. Its country code table is reused.
- The model catalog is generated with `tools/gen-models.py` from [unifi-emu](https://github.com/jamesbraid/unifi-emu) (MIT).
- The switch keys and their mapping were captured from UniFi Network 10.6.109 for this package.

## Tests

`tests/run.sh` runs the unit tests in a Linux environment with ucode and its fs, uci, socket, struct and zlib modules, plus mbedTLS headers. It tests the codec against vectors from Go's crypto library, and the switch and Wi-Fi translations against captured controller configurations.
