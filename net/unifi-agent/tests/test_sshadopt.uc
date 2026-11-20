// SSH adoption: request parsing and the temporary account.
import * as t from 'assert';
import * as ssh from 'unifi.sshadopt';
import { readfile } from 'fs';

const K = '0123456789abcdef0123456789ABCDEF';

t.eq(ssh.parse(`/usr/bin/syswrapper.sh set-adopt http://10.0.0.2:8080/inform ${K}`),
	{ url: 'http://10.0.0.2:8080/inform', key: lc(K) }, 'set-adopt');
t.eq(ssh.parse('mca-cli-op set-inform http://10.0.0.2:8080/inform'), { url: 'http://10.0.0.2:8080/inform', key: null }, 'set-inform');
t.eq(ssh.parse(`syswrapper.sh set-adopt http://evil.example/inform ${K}`), null, 'host name refused');
t.eq(ssh.parse(`syswrapper.sh set-adopt http://10.0.0.2:8080/x;reboot ${K}`), null, 'odd URL refused');
t.eq(ssh.parse('cat /etc/board.info'), null, 'other command ignored');
t.eq(ssh.parse(`syswrapper.sh set-adopt http://10.0.0.010:8080/inform ${K}`), null, 'octal-looking octet refused');

system('rm -rf /tmp/ssh-t && mkdir -p /tmp/ssh-t/etc && printf "root:x:0:0:root:/root:/bin/ash\\n" > /tmp/ssh-t/etc/passwd && printf "root:::0:99999:7:::\\n" > /tmp/ssh-t/etc/shadow && : > /tmp/ssh-t/etc/shells');
t.ok(ssh.account(true, '/tmp/ssh-t'), 'account added');
t.ok(!ssh.account(true, '/tmp/ssh-t'), 'second add is a no-op');
t.ok(index(readfile('/tmp/ssh-t/etc/passwd'), 'ubnt:x:1100') >= 0, 'passwd line');
t.ok(index(readfile('/tmp/ssh-t/etc/shells'), 'ssh-adopt') >= 0, 'shell listed');
t.ok(ssh.account(false, '/tmp/ssh-t'), 'account removed');
t.eq(readfile('/tmp/ssh-t/etc/passwd'), 'root:x:0:0:root:/root:/bin/ash\n', 'root untouched');

t.done();
