import Testing
@testable import DFileManager

// One Kermo per config (`HandOff`): which running Kermo gets a second launch.

@Test func aSecondLaunchGoesToTheHolder() {
    #expect(HandOff.pick(lock: 20, running: [10, 20, 30], me: 30) == 20)   // the lock's pid
    #expect(HandOff.pick(lock: 99, running: [10, 30], me: 30) == nil)      // stale, or an unbundled build: not 10 (its own config?)
    #expect(HandOff.pick(lock: nil, running: [10, 30], me: 30) == 10)      // a Kermo before 2.3 writes none: the one other
    #expect(HandOff.pick(lock: nil, running: [10, 20, 30], me: 30) == nil) // two others: which one is unknown
    #expect(HandOff.pick(lock: 30, running: [30], me: 30) == nil)          // only this one: launch as before
    #expect(HandOff.pick(lock: nil, running: [], me: 30) == nil)           // an unbundled build keeps it
}
