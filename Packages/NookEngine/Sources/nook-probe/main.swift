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

default:
    print("""
    nook-probe — M1 spike harness
      dump                        introspect private assessment API
      positions                   print MenuBarAgent item order
      conceal <sec> [bundleID…]   timed hide of third-party items
      ax                          enumerate MenuBarAgent AX tree
    """)
}
