'use strict';

// Node 23+ treats a positional argument of `node --test` as a file path or a
// glob, no longer as a directory to walk, so `node --test companion/test`
// resolves this directory to its index.js. Loading the suites here keeps that
// command working. Older Node versions walk the directory themselves.
require('./server.test.js');
