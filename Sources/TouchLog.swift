import AppKit

/// `--touches`: prints raw finger frames to the terminal without touching any window.
/// If the private struct layout is wrong, values fall outside 0..1 and show up here.
enum TouchLog {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let queue = DispatchQueue(label: "tutamak.touchlog")
        let mt = Multitouch.shared
        var indexOf: [UnsafeMutableRawPointer: Int] = [:]
        var lastTouching: [Int: Int] = [:]
        var frames = 0

        mt.onFrame = { device, touches, time in
            queue.async {
                frames += 1
                let dev = indexOf[device] ?? -1
                let touching = touches.filter { $0.state == 4 }.count
                let anomalies = touches.filter { t in
                    !(0...7).contains(t.state)
                        || !t.x.isFinite || !t.y.isFinite
                        || t.x < -0.1 || t.x > 1.1 || t.y < -0.1 || t.y > 1.1
                }
                let changed = lastTouching[dev] != touching
                lastTouching[dev] = touching

                if changed || frames % 20 == 0 || !anomalies.isEmpty {
                    var line = String(format: "[trackpad %d] t=%.3f touching=%d", dev, time, touching)
                    for t in touches {
                        line += String(format: " | id=%d state=%d x=%.3f y=%.3f size=%.2f", t.id, t.state, t.x, t.y, t.size)
                    }
                    print(line)
                }
                if !anomalies.isEmpty {
                    print("⚠︎ ANOMALOUS VALUE: the MTFinger layout may have changed in this macOS version")
                }
                if changed, touching == 4 {
                    print("→ 4 fingers detected")
                }
            }
        }

        let count = mt.start()
        queue.sync {
            for (i, device) in mt.devices.enumerated() { indexOf[device] = i }
        }
        print("Tutamak touch log: found \(count) trackpad(s).")
        for (i, device) in mt.devices.enumerated() {
            print("  trackpad \(i): \(mt.isBuiltIn(device) ? "built-in" : "external")")
        }
        if count == 0 {
            print("No trackpad found.")
            exit(1)
        }
        print("Put your fingers on the trackpad and slide with four. Press Ctrl-C to quit.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            queue.async {
                if frames == 0 {
                    print("No frames in 15 seconds. Allow this terminal under System Settings > Privacy & Security > Input Monitoring and try again.")
                }
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.run()
        exit(0)
    }
}
