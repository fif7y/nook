// nook-probe — M1 spike harness. Throwaway.
// Proves the macOS 27 engine mechanisms on this machine before any UI exists.
//
//   nook-probe dump                      introspect the private assessment API
//   nook-probe positions                 print MenuBarAgent's persisted item order
//   nook-probe conceal <sec> [bundle…]   hide all third-party items except the
//                                        listed bundle IDs for <sec> seconds
//   nook-probe ax                        enumerate MenuBarAgent's AX item tree

import AppKit
import ApplicationServices
import Foundation
import NookCore
import NookEngine

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch args.first {
case "dump":
    print("MenuBarClientCore available: \(AssessmentMode.isAvailable)")
    print(AssessmentMode.apiDescription)

case "positions":
    let ordered = AgentPositions.readOrdered()
    guard !ordered.isEmpty else {
        fail("No \(AgentPositions.positionsKey) values in \(AgentPositions.domain) — key name or domain may have changed on this build.")
    }
    for (tag, position) in ordered {
        print(String(format: "%12.3f  %@", position, tag))
    }

case "conceal":
    guard args.count >= 2, let seconds = TimeInterval(args[1]) else {
        fail("usage: nook-probe conceal <seconds> [allowedBundleID…]")
    }
    let allowed = Array(args.dropFirst(2))
    guard AssessmentMode.isAvailable else {
        fail("MenuBarClientCore not available on this build.")
    }
    print("Activating assertion — allowed system items: all, allowed bundles: \(allowed.isEmpty ? "none" : allowed.joined(separator: ", "))")
    let done = DispatchSemaphore(value: 0)
    let assertion = AssessmentMode.activate(bundleIDs: allowed) { error in
        if let error {
            print("activation completion: ERROR \(error)")
        } else {
            print("activation completion: OK — third-party items should now be hidden")
        }
        done.signal()
    }
    guard let assertion else {
        fail("Activation could not be attempted (nil assertion) — check `nook-probe dump` for the real selector names.")
    }
    // Completion is asynchronous; give it a bounded wait, then hold the hide.
    _ = done.wait(timeout: .now() + 5)
    print("Holding for \(seconds)s — look at the menu bar…")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    assertion.invalidate()
    print("Invalidated — items should be restored.")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

case "ax":
    guard AXIsProcessTrusted() else {
        fail("Not AX-trusted. Grant Accessibility to the invoking app (System Settings › Privacy & Security › Accessibility), then re-run.")
    }
    guard let agent = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.MenuBarAgent"
    }) else {
        fail("com.apple.MenuBarAgent is not running — menubar host name may differ on this build.")
    }
    print("MenuBarAgent pid \(agent.processIdentifier)")
    let app = AXUIElementCreateApplication(agent.processIdentifier)

    func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
    func describe(_ element: AXUIElement, depth: Int) {
        let role = attr(element, kAXRoleAttribute) as? String ?? "?"
        let title = attr(element, kAXTitleAttribute) as? String ?? ""
        let identifier = attr(element, kAXIdentifierAttribute) as? String ?? ""
        let description = attr(element, kAXDescriptionAttribute) as? String ?? ""
        var frameText = ""
        if let frameValue = attr(element, "AXFrame"), CFGetTypeID(frameValue) == AXValueGetTypeID() {
            var rect = CGRect.zero
            // AXValueGetValue is safe here: type checked above.
            AXValueGetValue((frameValue as! AXValue), .cgRect, &rect)
            frameText = String(format: " @(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
        }
        let indent = String(repeating: "  ", count: depth)
        let details = [title, identifier, description].filter { !$0.isEmpty }.joined(separator: " | ")
        print("\(indent)\(role)  \(details)\(frameText)")
        if depth < 4, let children = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                describe(child, depth: depth + 1)
            }
        }
    }
    describe(app, depth: 0)

case "conceal-sys":
    // conceal-sys <seconds> <maxSysID> [allowedBundleID…] — extended system-ID
    // probe: do IDs above 8 keep Now Playing / camera extras visible?
    guard args.count >= 3, let seconds = TimeInterval(args[1]), let maxID = Int(args[2]) else {
        fail("usage: nook-probe conceal-sys <seconds> <maxSysID> [allowedBundleID…]")
    }
    let allowed = Array(args.dropFirst(3))
    print("Assertion with system IDs 0…\(maxID), bundles: \(allowed.joined(separator: ", "))")
    let done = DispatchSemaphore(value: 0)
    let assertion = AssessmentMode.activate(
        rawSystemItems: Array(0...maxID),
        bundleIDs: allowed
    ) { error in
        print("completion: \(error.map { "ERROR \($0)" } ?? "OK")")
        done.signal()
    }
    guard let assertion else { fail("activation not attempted") }
    _ = done.wait(timeout: .now() + 5)
    print("holding \(seconds)s…")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    assertion.invalidate()
    print("invalidated")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

case "enum":
    // Print exactly what the engine's enumerator produces: IDs + frames.
    let done = DispatchSemaphore(value: 0)
    Task {
        let enumerator = ItemEnumerator()
        for item in await enumerator.snapshotItems() {
            print(String(format: "%8.1f  %@", item.frame.minX, item.id.rawValue))
        }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

case "engine-test":
    guard args.count >= 2 else {
        fail("usage: nook-probe engine-test <bundleIDToHide> [soakCycles]")
    }
    let bundleToHide = args[1]
    let soakCycles = args.count >= 3 ? Int(args[2]) ?? 0 : 0
    // Keep the main run loop pumping: assertion completions and AX callbacks
    // are main-queue delivered. Blocking main with a semaphore deadlocks.
    nonisolated(unsafe) var testDone = false
    Task {
        let engine = EngineGoldenGate()
        Task {
            for await event in engine.events {
                print("  [engine event] \(event)")
            }
        }
        await engine.start()

        let before = await engine.snapshot()
        print("observed \(before.items.count) items")
        let target = before.items.first { $0.id.bundleID == bundleToHide }
        guard let target else {
            print("FAIL: \(bundleToHide) not observed in the menubar")
            testDone = true
            return
        }
        print("target: \(target.id.rawValue) at \(target.frame.map(String.init(describing:)) ?? "?")")

        var model = SectionModel()
        model.assignments[target.id] = .hidden
        await engine.setModel(model)
        var check = await engine.snapshot()
        let hiddenOK = !check.items.contains { $0.id.bundleID == bundleToHide }
        print("after conceal: target \(hiddenOK ? "GONE ✓" : "STILL VISIBLE ✗")")

        // Regression: re-applying the same model while concealed must be a
        // no-op (concealed items are unobservable — the engine must not
        // conclude "nothing to conceal" and resurrect them).
        await engine.setModel(model)
        await engine.setModel(model)
        try? await Task.sleep(for: .seconds(1))
        check = await engine.snapshot()
        let stableOK = !check.items.contains { $0.id.bundleID == bundleToHide }
        print("after re-apply ×2: target \(stableOK ? "STILL GONE ✓" : "REAPPEARED ✗")")

        await engine.reveal([.hidden])
        check = await engine.snapshot()
        let revealedOK = check.items.contains { $0.id.bundleID == bundleToHide }
        print("after reveal: target \(revealedOK ? "BACK ✓" : "MISSING ✗")")

        var soakFailures = 0
        if soakCycles > 0 {
            print("soak: \(soakCycles) conceal/reveal cycles…")
            for cycle in 1...soakCycles {
                await engine.conceal()
                let concealed = await engine.snapshot()
                let concealedOK = !concealed.items.contains { $0.id.bundleID == bundleToHide }
                await engine.reveal([.hidden])
                let revealed = await engine.snapshot()
                let cycleOK = concealedOK && revealed.items.contains { $0.id.bundleID == bundleToHide }
                if !cycleOK {
                    soakFailures += 1
                    print("  cycle \(cycle): FAIL (concealed=\(concealedOK))")
                }
            }
            print("soak result: \(soakCycles - soakFailures)/\(soakCycles) clean cycles")
        }

        await engine.conceal()
        await engine.setModel(SectionModel())  // restore: nothing hidden
        await engine.stop()
        print(hiddenOK && stableOK && revealedOK && soakFailures == 0 ? "ENGINE TEST PASS" : "ENGINE TEST FAIL")
        testDone = true
    }
    while !testDone {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

default:
    print("""
    nook-probe — M1 spike harness
      dump                        introspect private assessment API
      positions                   print MenuBarAgent item order
      conceal <sec> [bundleID…]   timed hide of third-party items
      ax                          enumerate MenuBarAgent AX tree
    """)
}
