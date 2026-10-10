#!/bin/zsh
# Runs the test suite. With Command Line Tools only (no Xcode), SwiftPM's explicit-module build
# drops the swift-testing macro plugin on a fresh compile ("plugin for module 'TestingMacros' not
# found"). Loading the plugin explicitly works around it.
cd "${0:A:h}"
P=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
if [[ $(xcode-select -p) == /Library/Developer/CommandLineTools && -f $P ]]; then
  exec swift test -Xswiftc -load-plugin-library -Xswiftc $P "$@"
fi
exec swift test "$@"
