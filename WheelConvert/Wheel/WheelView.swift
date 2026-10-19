import AppKit

/// Brand colors.
enum Brand {
    static let accentTop = NSColor(srgbRed: 0.42, green: 0.36, blue: 1.0, alpha: 1)   // violet
    static let accentBottom = NSColor(srgbRed: 0.16, green: 0.62, blue: 1.0, alpha: 1) // blue
    static var accent: NSColor { NSColor(srgbRed: 0.33, green: 0.45, blue: 1.0, alpha: 1) }
}

/// Radial menu of petals around a central label. It is also the drop target for the drag that opened it.
final class WheelView: NSView {
    var onDrop: ((WheelItem, [URL]) -> Void)?
    var onDragInsideChanged: ((Bool) -> Void)?
    private(set) var isDragInside = false

    private(set) var items: [WheelItem] = []
    private var idleText = ""
    private var highlighted: Int? {
        didSet { if highlighted != oldValue { highlightChanged() } }
    }

    private let backdrop = NSVisualEffectView()
    /// Holds the drawn layers. They need a view of their own above the backdrop: AppKit restacks a
    /// view's subview layers above layers added to it directly, which hid every label in Glass mode.
    private let ringView = NSView()
    private let ringLayer = CALayer()
    private var petalLayers: [CAShapeLayer] = []
    private var labelLayers: [CATextLayer] = []
    private var iconLayers: [CALayer] = []
    private let hubLayer = CAShapeLayer()
    private let hubText = CATextLayer()
    private let feedback = WheelFeedback()

    private(set) var outerRadius: CGFloat = 132
    let hubRadius: CGFloat = 46
    let innerRadius: CGFloat = 56
    static let margin: CGFloat = 26

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)
        ringView.wantsLayer = true
        ringView.autoresizingMask = [.width, .height]
        ringView.frame = bounds
        addSubview(ringView)
        ringLayer.masksToBounds = false
        ringView.layer?.addSublayer(ringLayer)
        hubText.actions = Self.noFade
        hubText.alignmentMode = .center
        hubText.isWrapped = true
        hubText.truncationMode = .end
        ringLayer.addSublayer(hubLayer)
        ringLayer.addSublayer(hubText)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conversion wheel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Text layers render their contents later, at display time, outside any transaction that turns
    /// animations off; without this the old and new titles crossfade, looking like two wheels.
    static let noFade: [String: CAAction] = ["contents": NSNull(), "string": NSNull(), "position": NSNull(), "bounds": NSNull()]

    static func outerRadius(for count: Int) -> CGFloat {
        count <= 8 ? 132 : min(176, 132 + CGFloat(count - 8) * 9)
    }

    static func diameter(for count: Int) -> CGFloat { 2 * (outerRadius(for: count) + margin) }

    func configure(items: [WheelItem], idleText: String) {
        self.items = items
        self.idleText = idleText
        outerRadius = Self.outerRadius(for: items.count)
        highlighted = nil
        rebuild()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        ringView.frame = bounds
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Geometry

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { items.isEmpty ? 0 : 2 * .pi / CGFloat(items.count) }

    /// Angle measured clockwise from 12 o'clock, in radians.
    private func clockAngle(of point: CGPoint) -> CGFloat {
        let dx = point.x - center.x, dy = point.y - center.y
        var angle = .pi / 2 - atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        return angle.truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// The petal under a point, if any. The hub and the area outside the ring select nothing.
    func petal(at point: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance >= hubRadius + 4, distance <= outerRadius + Self.margin * 0.8 else { return nil }
        let index = Int(((clockAngle(of: point) + step / 2) / step).rounded(.down)) % items.count
        return index
    }

    /// Standard (counter-clockwise from +x) angle for a clock angle.
    private func standardAngle(_ clock: CGFloat) -> CGFloat { .pi / 2 - clock }

    private func petalPath(index: Int) -> CGPath {
        let gap: CGFloat = items.count == 1 ? 0 : 3.2
        let midClock = CGFloat(index) * step
        let outerInset = gap / 2 / outerRadius, innerInset = gap / 2 / innerRadius
        let a0 = standardAngle(midClock - step / 2), a1 = standardAngle(midClock + step / 2)
        if items.count == 1 {
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: 2 * outerRadius, height: 2 * outerRadius))
            path.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: 2 * innerRadius, height: 2 * innerRadius))
            return path
        }
        // Outer arc runs clockwise from a0 to a1, inner arc back. Each of the four corners is cut
        // back by the same distance along both edges and joined with a curve, so every petal has
        // identical, symmetric corners.
        let outerFrom = a0 - outerInset, outerTo = a1 + outerInset
        let innerFrom = a1 + innerInset, innerTo = a0 - innerInset
        func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)) }
        func toward(_ from: CGPoint, _ to: CGPoint, _ distance: CGFloat) -> CGPoint {
            let length = max(hypot(to.x - from.x, to.y - from.y), 0.001)
            return CGPoint(x: from.x + (to.x - from.x) * distance / length, y: from.y + (to.y - from.y) * distance / length)
        }
        let c0 = point(outerRadius, outerFrom), c1 = point(outerRadius, outerTo)
        let c2 = point(innerRadius, innerFrom), c3 = point(innerRadius, innerTo)
        let edge = outerRadius - innerRadius
        let ro = min(11, edge / 3, outerRadius * (outerFrom - outerTo) / 3)
        let ri = min(7, edge / 4, innerRadius * (innerTo - innerFrom) / 3)
        let path = CGMutablePath()
        path.move(to: toward(c0, c3, ro))
        path.addQuadCurve(to: point(outerRadius, outerFrom - ro / outerRadius), control: c0)
        path.addArc(center: center, radius: outerRadius, startAngle: outerFrom - ro / outerRadius, endAngle: outerTo + ro / outerRadius, clockwise: true)
        path.addQuadCurve(to: toward(c1, c2, ro), control: c1)
        path.addLine(to: toward(c2, c1, ri))
        path.addQuadCurve(to: point(innerRadius, innerFrom + ri / innerRadius), control: c2)
        path.addArc(center: center, radius: innerRadius, startAngle: innerFrom + ri / innerRadius, endAngle: innerTo - ri / innerRadius, clockwise: false)
        path.addQuadCurve(to: toward(c3, c0, ri), control: c3)
        path.closeSubpath()
        return path
    }

    // MARK: Layers

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ringLayer.frame = bounds
        (petalLayers as [CALayer] + labelLayers + iconLayers).forEach { $0.removeFromSuperlayer() }
        petalLayers = []; labelLayers = []; iconLayers = []
        let scale = window?.backingScaleFactor ?? 2

        for (index, item) in items.enumerated() {
            let path = petalPath(index: index)
            let petal = CAShapeLayer()
            petal.path = path
            petal.fillRule = .evenOdd
            petal.lineWidth = 1
            ringLayer.insertSublayer(petal, below: hubLayer)
            petalLayers.append(petal)

            let midClock = CGFloat(index) * step
            let midRadius = (innerRadius + outerRadius) / 2 + 2
            let anchor = CGPoint(x: center.x + midRadius * cos(standardAngle(midClock)), y: center.y + midRadius * sin(standardAngle(midClock)))
            let arcWidth = items.count == 1 ? 120 : max(40, 2 * midRadius * sin(step / 2) - 10)

            let text = CATextLayer()
            text.actions = Self.noFade
            text.contentsScale = scale
            text.alignmentMode = .center
            text.truncationMode = .end
            let font = fittedFont(for: item.label, width: arcWidth)
            text.font = font
            text.fontSize = font.pointSize
            text.string = item.label
            let textHeight = ceil(font.ascender - font.descender) + 2
            var textRect = CGRect(x: anchor.x - arcWidth / 2, y: anchor.y - textHeight / 2, width: arcWidth, height: textHeight)
            if let symbol = item.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
                let icon = CALayer()
                icon.actions = Self.noFade
                icon.contentsScale = scale
                icon.contentsGravity = .resizeAspect
                let size = image.size
                icon.frame = CGRect(x: anchor.x - size.width / 2, y: anchor.y + 2, width: size.width, height: size.height)
                icon.contents = image
                icon.setValue(symbol, forKey: "symbol")
                ringLayer.addSublayer(icon)
                iconLayers.append(icon)
                textRect.origin.y = anchor.y - textHeight - 2
            } else {
                iconLayers.append(CALayer())
            }
            text.frame = textRect
            ringLayer.addSublayer(text)
            labelLayers.append(text)
        }

        let hub = CGMutablePath()
        hub.addEllipse(in: CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2))
        hubLayer.path = hub
        hubLayer.lineWidth = 1
        hubText.contentsScale = scale
        let hubFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        hubText.font = hubFont
        hubText.fontSize = 11
        hubText.frame = CGRect(x: center.x - hubRadius + 7, y: center.y - 15, width: (hubRadius - 7) * 2, height: 30)
        updateHubText()
        backdrop.maskImage = maskImage()
        applyColors()
    }

    private func fittedFont(for label: String, width: CGFloat) -> NSFont {
        var size: CGFloat = 12
        while size > 8 {
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            if (label as NSString).size(withAttributes: [.font: font]).width <= width { return font }
            size -= 0.5
        }
        return NSFont.systemFont(ofSize: 8, weight: .bold)
    }

    /// The ring and hub shape, used to clip the blurred backdrop.
    private func maskImage() -> NSImage {
        let paths = (0..<items.count).map(petalPath(index:))
        let hubRect = CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)
        return NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            for path in paths {
                context.addPath(path)
                context.fillPath(using: .evenOdd)
            }
            context.fillEllipse(in: hubRect)
            return true
        }
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let solid = AppSettings.shared.wheelTheme == .solid
        backdrop.isHidden = solid
        let petalFill = solid
            ? (dark ? NSColor(white: 0.18, alpha: 0.98) : NSColor(white: 0.97, alpha: 0.98))
            : (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.45))
        let stroke = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.09)
        let labelColor = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.08, alpha: 0.88)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, petal) in petalLayers.enumerated() {
            let selected = index == highlighted
            petal.fillColor = (selected ? Brand.accent : petalFill).cgColor
            petal.strokeColor = (selected ? Brand.accent : stroke).cgColor
            labelLayers[safe: index]?.foregroundColor = (selected ? NSColor.white : labelColor).cgColor
            if let icon = iconLayers[safe: index], let symbol = icon.value(forKey: "symbol") as? String {
                icon.contents = tintedSymbol(symbol, color: selected ? .white : labelColor)
            }
        }
        hubLayer.fillColor = (solid ? petalFill : (dark ? NSColor(white: 0, alpha: 0.22) : NSColor(white: 1, alpha: 0.7))).cgColor
        hubLayer.strokeColor = stroke.cgColor
        hubText.foregroundColor = (dark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.62)).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.45 : 0.22
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        CATransaction.commit()
    }

    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    private func updateHubText() {
        let text: String
        if let highlighted, let item = items[safe: highlighted] { text = item.title } else { text = idleText }
        hubText.string = text
        let lines: CGFloat = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width > (hubRadius - 7) * 2 ? 2 : 1
        hubText.frame = CGRect(x: center.x - hubRadius + 7, y: center.y - 7 * lines - 1, width: (hubRadius - 7) * 2, height: 14 * lines + 2)
    }

    private func highlightChanged() {
        applyColors()
        updateHubText()
        if highlighted != nil { feedback.play() }
        if let highlighted, let item = items[safe: highlighted] {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: item.title])
        }
    }

    /// Lights a petal without a drag, for snapshots.
    func debugHighlight(_ index: Int) { highlighted = index }

    // MARK: Intro

    /// Pops the wheel in when it appears.
    func animateIn() {
        guard let layer else { return }
        layer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        layer.add(fade, forKey: "fade")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Scale the whole wheel, blurred backdrop included, about its center. The view's layer
        // pivots on its anchor point, so the center is held in place with a translation.
        let pivot = CGPoint(x: bounds.midX - bounds.width * layer.anchorPoint.x, y: bounds.midY - bounds.height * layer.anchorPoint.y)
        let start = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), CATransform3DMakeScale(0.82, 0.82, 1)),
                                        CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.damping = 18
        spring.stiffness = 320
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "intro")
    }

    // MARK: Dragging destination

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(sender)
        guard highlighted != nil else { return [] }
        // Never accept as a move: the source would delete the original.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    private func updateHighlight(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        highlighted = petal(at: point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragInside = true
        onDragInsideChanged?(true)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragInside = false
        highlighted = nil
        onDragInsideChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted != nil && !items.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = highlighted, let item = items[safe: index] else { return false }
        let urls = DragMonitor.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop?(item, urls) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragInside = false
        onDragInsideChanged?(false)
    }

    // MARK: Accessibility (keyboard/VoiceOver users can press petals after opening with a drag)

    override func accessibilityChildren() -> [Any]? {
        items.enumerated().map { index, item in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(item.title)
            element.setAccessibilityParent(self)
            let rect = petalPath(index: index).boundingBox
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        }
    }
}

/// Short tick and trackpad haptic when a petal lights up.
final class WheelFeedback {
    private var sounds: [NSSound] = []
    private var next = 0

    func play() {
        guard AppSettings.shared.soundsAndHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if sounds.isEmpty {
            let data = Self.tickWAV()
            sounds = (0..<4).compactMap { _ in NSSound(data: data) }
            sounds.forEach { $0.volume = 0.35 }
        }
        guard !sounds.isEmpty else { return }
        let sound = sounds[next % sounds.count]
        next += 1
        sound.stop()
        sound.play()
    }

    /// A 28 ms decaying click synthesized as 16-bit mono WAV.
    static func tickWAV() -> Data {
        let rate = 44_100, count = Int(Double(rate) * 0.028)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let envelope = exp(-t * 180)
            let value = (sin(2 * .pi * 2_400 * t) * 0.7 + sin(2 * .pi * 3_900 * t) * 0.3) * envelope
            samples[i] = Int16(max(-1, min(1, value)) * 22_000)
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(rate).littleEndian); append(UInt32(rate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes).littleEndian)
        samples.forEach { append($0.littleEndian) }
        return data
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
