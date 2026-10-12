#!/bin/zsh
# Runs the test suite. With Command Line Tools only (no Xcode), SwiftPM's explicit-module build
# drops the swift-testing macro plugin on a fresh compile ("plugin for module 'TestingMacros' not
# found"). Loading the plugin explicitly works around it.
cd "${0:A:h}"
# DFM_TEST_DISK: a volume for the build and the tests' files instead of this Mac's disk, say a spare card. "ram" makes
# a 4 GB RAM disk (once; gone at restart). A set volume that's missing stops the run, or in a terminal offers the RAM
# disk. A build folder per checkout, so worktrees don't share one; ".noindex" keeps Spotlight out.
ramdisk() {
  [[ -d /Volumes/KermoRAM ]] || diskutil erasevolume APFS KermoRAM $(hdiutil attach -nomount ram://8388608 2>/dev/null) >/dev/null
  DFM_TEST_DISK=/Volumes/KermoRAM
}
if [[ -n $DFM_TEST_DISK ]]; then
  [[ $DFM_TEST_DISK == ram ]] && ramdisk
  if [[ ! -w $DFM_TEST_DISK ]]; then
    if [[ -t 0 ]] && read -q "?test.sh: $DFM_TEST_DISK for tests is missing. Use a 4 GB RAM disk? [y/N] "; then
      echo; ramdisk
    else
      [[ -t 0 ]] && echo
      echo "test.sh: $DFM_TEST_DISK is missing. Insert it, or run with DFM_TEST_DISK=ram (RAM disk) or DFM_TEST_DISK= (this Mac's disk)."
      exit 1
    fi
  fi
  D=$DFM_TEST_DISK/kermo.noindex
  mkdir -p "$D/tmp" || exit 1
  export DFM_TEST_TMP=$D/tmp
  set -- --scratch-path "$D/build-${PWD:t}" "$@"
  echo "test.sh: building and testing on $DFM_TEST_DISK"
fi
P=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
if [[ $(xcode-select -p) == /Library/Developer/CommandLineTools && -f $P ]]; then
  exec swift test -Xswiftc -load-plugin-library -Xswiftc $P "$@"
fi
exec swift test "$@"
