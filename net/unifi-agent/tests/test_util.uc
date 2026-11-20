// Natural order of port names.
import * as t from 'assert';
import * as util from 'unifi.util';

t.eq(sort([ 'lan10', 'lan2', 'lan1', 'wan', 'lan11' ], util.natcmp), [ 'lan1', 'lan2', 'lan10', 'lan11', 'wan' ], 'natural order');
t.done();
