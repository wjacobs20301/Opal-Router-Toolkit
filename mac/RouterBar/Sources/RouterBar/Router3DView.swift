import SwiftUI

/// Real-time 3D model of the GL-SFT1200 (proportions from its 118 × 85 × 30 mm body):
/// white rounded body, slatted side vents, paddle antennas, rear port panel, and the
/// front LED slot, which glows with the router's actual LED state.
/// It sways slowly; drag to spin it.
struct Router3DView: View {
    let state: LEDState?
    var sway = true
    /// Fixed time for snapshots (nil = live).
    var fixedTime: TimeInterval? = nil
    /// Extra yaw for snapshots (radians).
    var yawOffset: Double = 0

    static let bleed: CGFloat = 26

    @State private var dragYaw: Double = 0
    @State private var dragStart: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: fixedTime != nil)) { ctx in
            let t = fixedTime ?? LEDClock.at(ctx.date)
            let yaw = 0.62 + (sway ? 0.28 * sin(t * 0.45) : 0) + dragYaw + yawOffset
            let led = state?.frame(at: t) ?? LEDFrame(color: .off, level: 0)
            Canvas { gc, size in
                OpalRenderer(size: size, yaw: yaw, led: led, bleed: Router3DView.bleed).draw(in: &gc)
            }
            // Draw past the view's edges so the glow and shadow fade out instead of being cut off.
            .padding(-Router3DView.bleed)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in dragYaw = dragStart + Double(v.translation.width) * 0.02 }
                .onEnded { _ in dragStart = dragYaw }
        )
        .help("Drag to spin")
    }
}

// MARK: - Geometry

private struct V3 {
    var x, y, z: Double
    static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: V3, s: Double) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    var normalized: V3 { let l = sqrt(dot(self)); return l > 0 ? self * (1 / l) : self }
}

private struct Face { let pts: [V3]; let normal: V3 }

/// Rounded rectangle in the (y, z) plane, counter-clockwise when viewed from +x.
private func roundedProfile(y0: Double, y1: Double, z0: Double, z1: Double,
                            rTop: Double, rBottom: Double, steps: Int = 7) -> [(Double, Double)] {
    var pts: [(Double, Double)] = []
    func arc(cy: Double, cz: Double, r: Double, from a0: Double) {
        for i in 0...steps {
            let a = a0 + Double(i) / Double(steps) * (.pi / 2)
            pts.append((cy + r * sin(a), cz + r * cos(a)))
        }
    }
    // Point = center + r·(sin a, cos a) in (y, z). Corners go around:
    // back-bottom → back-top → front-top → front-bottom (z+ is back).
    arc(cy: y0 + rBottom, cz: z1 - rBottom, r: rBottom, from: -.pi / 2)    // back-bottom
    arc(cy: y1 - rTop, cz: z1 - rTop, r: rTop, from: 0)                    // back-top
    arc(cy: y1 - rTop, cz: z0 + rTop, r: rTop, from: .pi / 2)              // front-top
    arc(cy: y0 + rBottom, cz: z0 + rBottom, r: rBottom, from: .pi)         // front-bottom
    return pts
}

/// Extrudes a (y, z) profile along x from x0 to x1: curved strip faces + flat end caps.
private func extrude(_ prof: [(Double, Double)], x0: Double, x1: Double) -> (strip: [Face], capL: Face, capR: Face) {
    var strip: [Face] = []
    let n = prof.count
    // Profile winding check (so normals point outward regardless of direction).
    var area = 0.0
    for i in 0..<n { let a = prof[i], b = prof[(i + 1) % n]; area += a.1 * b.0 - b.1 * a.0 }
    let sign: Double = area > 0 ? 1 : -1
    for i in 0..<n {
        let a = prof[i], b = prof[(i + 1) % n]
        let dy = b.0 - a.0, dz = b.1 - a.1
        let nrm = V3(x: 0, y: -dz * sign, z: dy * sign).normalized
        strip.append(Face(pts: [V3(x: x0, y: a.0, z: a.1), V3(x: x1, y: a.0, z: a.1),
                                V3(x: x1, y: b.0, z: b.1), V3(x: x0, y: b.0, z: b.1)], normal: nrm))
    }
    let capL = Face(pts: prof.map { V3(x: x0, y: $0.0, z: $0.1) }, normal: V3(x: -1, y: 0, z: 0))
    let capR = Face(pts: prof.map { V3(x: x1, y: $0.0, z: $0.1) }, normal: V3(x: 1, y: 0, z: 0))
    return (strip, capL, capR)
}

// MARK: - Renderer

private struct OpalRenderer {
    let size: CGSize
    let yaw: Double
    let led: LEDFrame
    var bleed: CGFloat = 0

    // Real proportions (units of 100 mm): 118 × 30 × 85 mm.
    static let w = 1.18, h = 0.30, d = 0.85
    static let r = 0.11                           // rounding of the long top/bottom edges
    static let pitch = -0.40                      // camera looks slightly down
    static let light = V3(x: -0.35, y: 0.85, z: -0.45).normalized

    // Antenna paddles (flat, rounded), hinged on the short sides.
    static let antT = 0.05, antW = 0.22, antY0 = 0.03, antY1 = 0.80
    static let antLeftZ = -d / 2 + 0.17           // both antennas near the front,
    static let antRightZ = -d / 2 + 0.17          // at the same spot on each side

    var w: Double { Self.w }; var h: Double { Self.h }; var d: Double { Self.d }

    // Camera
    func view(_ p: V3, yaw: Double) -> V3 {
        let x1 = p.x * cos(yaw) - p.z * sin(yaw)
        let z1 = p.x * sin(yaw) + p.z * cos(yaw)
        let pc = Self.pitch
        return V3(x: x1, y: (p.y - h / 2) * cos(pc) - z1 * sin(pc), z: (p.y - h / 2) * sin(pc) + z1 * cos(pc))
    }
    func view(_ p: V3) -> V3 { view(p, yaw: yaw) }

    /// Fixed fit for any rotation, so the model doesn't change size while it turns.
    var fit: (scale: Double, center: CGPoint) {
        var corners: [V3] = []
        let hx: Double = w / 2 + Self.antT + 0.01
        let hz: Double = d / 2
        for sx in [-1.0, 1.0] {
            for sz in [-1.0, 1.0] {
                for y in [0.0, Self.antY1] { corners.append(V3(x: sx * hx, y: y, z: sz * hz)) }
            }
        }
        var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
        for k in 0..<16 {
            let yw = Double(k) / 16 * 2 * .pi
            for c in corners {
                let v = view(c, yaw: yw)
                minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y)
            }
        }
        let iw = Double(size.width - 2 * bleed), ih = Double(size.height - 2 * bleed)
        let s = min(iw / (maxX - minX), ih / (maxY - minY)) * 0.98
        return (s, CGPoint(x: size.width / 2 - (minX + maxX) / 2 * s, y: size.height / 2 + (minY + maxY) / 2 * s))
    }

    func draw(in gc: inout GraphicsContext) {
        let (s, c) = fit
        func project(_ p: V3) -> CGPoint { let v = view(p); return CGPoint(x: c.x + v.x * s, y: c.y - v.y * s) }
        func path(_ pts: [V3]) -> Path { var p = Path(); p.addLines(pts.map(project)); p.closeSubpath(); return p }
        func visible(_ n: V3) -> Bool { view(n + V3(x: 0, y: h / 2, z: 0)).z - view(V3(x: 0, y: h / 2, z: 0)).z < 0 }
        func lit(_ n: V3, base: Double, ambient: Double = 0.66) -> Color {
            let vn = view(n + V3(x: 0, y: h / 2, z: 0)) - view(V3(x: 0, y: h / 2, z: 0))
            let k = ambient + (1 - ambient) * max(0, vn.dot(Self.light))
            let v = base * k
            return Color(red: v * 0.995, green: v, blue: v * 1.01)
        }
        func fillFace(_ f: Face, base: Double) {
            let p = path(f.pts)
            let col = lit(f.normal, base: base)
            gc.fill(p, with: .color(col))
            gc.stroke(p, with: .color(col), lineWidth: 0.6)     // hide seams between strips
        }

        let ledOn: Double = led.color == LEDColor.off ? 0 : led.level
        let ledColor: Color
        switch led.color {
        case .blue: ledColor = Color(red: 0.22, green: 0.52, blue: 1.0)
        case .white: ledColor = Color(red: 0.98, green: 0.99, blue: 1.0)
        case .off: ledColor = .clear
        }

        // Ground shadow and LED spill on the surface in front.
        gc.drawLayer { l in
            l.addFilter(.blur(radius: s * 0.07))
            l.fill(path([V3(x: -w * 0.5, y: 0, z: -d * 0.5), V3(x: w * 0.5, y: 0, z: -d * 0.5),
                         V3(x: w * 0.5, y: 0, z: d * 0.5), V3(x: -w * 0.5, y: 0, z: d * 0.5)]),
                   with: .color(.black.opacity(0.28)))
        }
        if ledOn > 0 {
            gc.drawLayer { l in
                l.addFilter(.blur(radius: s * 0.2))
                l.fill(path([V3(x: -w * 0.35, y: 0, z: -d * 0.52), V3(x: w * 0.35, y: 0, z: -d * 0.52),
                             V3(x: w * 0.35, y: 0, z: -d * 1.25), V3(x: -w * 0.35, y: 0, z: -d * 1.25)]),
                       with: .color(ledColor.opacity(0.5 * ledOn)))
            }
        }

        // Parts
        let body = extrude(roundedProfile(y0: 0, y1: h, z0: -d / 2, z1: d / 2, rTop: Self.r, rBottom: Self.r * 0.8),
                           x0: -w / 2, x1: w / 2)
        func antenna(xOut: Double, zc: Double) -> [Face] {
            let prof = roundedProfile(y0: Self.antY0, y1: Self.antY1, z0: zc - Self.antW / 2, z1: zc + Self.antW / 2,
                                      rTop: Self.antW / 2 - 0.001, rBottom: 0.05, steps: 6)
            let x0 = xOut < 0 ? -w / 2 - 0.006 - Self.antT : w / 2 + 0.006
            let e = extrude(prof, x0: x0, x1: x0 + Self.antT)
            return e.strip + [e.capL, e.capR]
        }
        let antL = antenna(xOut: -1, zc: Self.antLeftZ)
        let antR = antenna(xOut: 1, zc: Self.antRightZ)

        func drawAntenna(_ faces: [Face]) {
            for f in faces where visible(f.normal) { fillFace(f, base: 0.95) }
        }
        // Each antenna lies entirely outside its side face, so it's in front of the body
        // exactly when that side faces the camera, and behind it otherwise.
        let leftInFront = visible(V3(x: -1, y: 0, z: 0))
        let rightInFront = visible(V3(x: 1, y: 0, z: 0))

        // Behind antennas first (painter's order), then body + details, then front antennas.
        if !leftInFront { drawAntenna(antL) }
        if !rightInFront { drawAntenna(antR) }

        for f in body.strip where visible(f.normal) { fillFace(f, base: 0.96) }

        // Short sides: flat caps with a slatted vent panel.
        for (cap, xs) in [(body.capL, -1.0), (body.capR, 1.0)] where visible(cap.normal) {
            fillFace(cap, base: 0.95)
            let x = xs * (w / 2 + 0.002)
            let inset = roundedProfile(y0: 0.035, y1: h - 0.035, z0: -d / 2 + 0.05, z1: d / 2 - 0.05,
                                       rTop: Self.r - 0.03, rBottom: Self.r * 0.8 - 0.03, steps: 6)
            let ventPath = path(inset.map { V3(x: x, y: $0.0, z: $0.1) })
            gc.fill(ventPath, with: .color(lit(cap.normal, base: 0.80)))
            gc.drawLayer { l in
                l.clip(to: ventPath)
                var k = -d
                while k < d {
                    var slat = Path()
                    slat.move(to: project(V3(x: x, y: 0, z: k)))
                    slat.addLine(to: project(V3(x: x, y: h, z: k + h * 0.9)))
                    l.stroke(slat, with: .color(lit(cap.normal, base: 0.62)), lineWidth: max(0.8, s * 0.012))
                    k += 0.045
                }
            }
        }

        // Back: recessed port panel (WAN, LAN, LAN, USB-A, USB-C).
        if visible(V3(x: 0, y: 0, z: 1)) {
            let z = d / 2 + 0.002
            // Seen from the back (x mirrored): WAN, LAN, LAN, USB-A, USB-C from left to right.
            let panel = path([V3(x: w * 0.30, y: 0.05, z: z), V3(x: -w * 0.42, y: 0.05, z: z),
                              V3(x: -w * 0.42, y: h - 0.05, z: z), V3(x: w * 0.30, y: h - 0.05, z: z)])
            gc.fill(panel, with: .color(lit(V3(x: 0, y: 0, z: 1), base: 0.84)))
            func port(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ shade: Double) {
                gc.fill(path([V3(x: x0, y: y0, z: z), V3(x: x1, y: y0, z: z), V3(x: x1, y: y1, z: z), V3(x: x0, y: y1, z: z)]),
                        with: .color(lit(V3(x: 0, y: 0, z: 1), base: shade)))
            }
            for i in 0..<3 { let x1 = w * 0.27 - Double(i) * 0.17; port(x1 - 0.14, x1, 0.09, 0.22, 0.45) }  // WAN, LAN, LAN
            port(-w * 0.25, -w * 0.18, 0.09, 0.22, 0.55)      // USB-A
            port(-w * 0.39, -w * 0.31, 0.12, 0.16, 0.35)      // USB-C power
        }

        // Front: the LED slot (thin capsule, low and centered) — this is the light.
        if visible(V3(x: 0, y: 0, z: -1)) {
            let z = -d / 2 - 0.002
            let y0 = 0.105, y1 = 0.13, x0 = -w * 0.30, x1 = w * 0.30    // centered on the front
            var cap: [V3] = []
            let rr = (y1 - y0) / 2
            for i in 0...8 { let a = .pi / 2 + Double(i) / 8 * .pi; cap.append(V3(x: x0 + rr + rr * cos(a), y: y0 + rr + rr * sin(a), z: z)) }
            for i in 0...8 { let a = -.pi / 2 + Double(i) / 8 * .pi; cap.append(V3(x: x1 - rr + rr * cos(a), y: y0 + rr + rr * sin(a), z: z)) }
            let slot = path(cap)
            if ledOn > 0 {
                gc.drawLayer { l in
                    l.addFilter(.blur(radius: s * 0.05))
                    l.fill(slot, with: .color(ledColor.opacity(0.95 * ledOn)))
                }
                gc.fill(slot, with: .color(ledColor.opacity(0.45 + 0.55 * ledOn)))
            } else {
                gc.fill(slot, with: .color(Color(white: 0.38)))
            }
        }

        if leftInFront { drawAntenna(antL) }
        if rightInFront { drawAntenna(antR) }
    }
}
