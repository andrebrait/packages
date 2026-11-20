// Natural order of port names.
import * as t from 'assert';
import * as util from 'unifi.util';
import { cursor } from 'uci';

t.eq(sort([ 'lan10', 'lan2', 'lan1', 'wan', 'lan11' ], util.natcmp), [ 'lan1', 'lan2', 'lan10', 'lan11', 'wan' ], 'natural order');
t.eq([ util.uci_list(''), util.uci_list(null), util.uci_list(' a \t b  '), util.uci_list([ 'x' ]) ],
	[ [], [], [ 'a', 'b' ], [ 'x' ] ], 'uci_list');

system('rm -rf /tmp/uci-u && mkdir -p /tmp/uci-u && printf "config device\n\toption name br\n\toption type bridge\n\tlist ports p1\n\nconfig bridge-vlan\n\toption device br\n\toption vlan 1\n\toption ports \'p1:u* p2:t p3\'\n" > /tmp/uci-u/network');
t.eq(util.bridge_members(cursor('/tmp/uci-u'), 'br'), [ 'p1', 'p2', 'p3' ], 'bridge_members');

t.done();
