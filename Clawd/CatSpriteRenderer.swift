import AppKit

class CatSpriteRenderer {
    // Spritesheet has 9 frames of 320×320 (Piskel 32×32 exported at 10×)
    private static let spritesheetFrameCount = 9
    let displaySize: CGFloat = 96  // 3× integer scale of 32px art
    let scale = 6                  // used by effect overlay system (96 / 16 grid cells)

    let layer = CALayer()
    private var frames: [CGImage] = []
    private var asleepFrames: [CGImage] = []
    private var currentlyFlipped = false

    enum Frame: Int {
        case idle = 0
        case walkA = 1
        case walkB = 2
        case blink = 3
        case happy = 4
        case surprised = 5
        case angry = 6
        case sad = 7
        case love = 8
        case sleepy = 9
        case smug = 10
        case scared = 11
        case dead = 12
        case wink = 13
        case asleep = 14   // separate sprite PNG used for resting/asleep states
    }

    // Map each Frame to a spritesheet slice index (0-based, left-to-right).
    // Tuned for the Shanks reference frames: 0 neutral, 1-2 walking variants,
    // 3 closed-eyes, 4 laughing/teeth, 5 wide-open-mouth, 6 calm, 7 SUNGLASSES,
    // 8 subtle smile.
    //
    // Where a dedicated frame doesn't exist, we map to whichever frame reads
    // closest visually — overlays (sparkle / sweat / anger mark / skull) and
    // animations (shake / tremble / bounce) carry the rest of the emotional
    // signal.
    private static let spritesheetIndex: [Frame: Int] = [
        .idle:      0,
        .walkA:     1,
        .walkB:     2,
        .blink:     3,
        .happy:     4,  // open-mouth laugh w/ teeth
        .love:      4,  // happy laugh + heart overlay
        .surprised: 5,  // wide-open mouth
        .scared:    5,  // same, w/ tremble + sweat
        .angry:     5,  // same, w/ shake + anger mark
        .sad:       8,  // subtle face — sad-ish (least-bad fit)
        .smug:      7,  // sunglasses, perfect
        .wink:      7,  // sunglasses
        .sleepy:    3,  // closed eyes
        .dead:      3,  // closed eyes + skull overlay
    ]

    init() {
        layer.frame = CGRect(x: 0, y: 0, width: displaySize, height: displaySize)
        layer.magnificationFilter = .nearest
        layer.minificationFilter  = .nearest
        layer.contentsGravity     = .resizeAspect
        loadSpritesheet()
        loadAsleepSprite()
        setFrame(.idle)
    }

    private func loadSpritesheet() {
        guard let url = Bundle.module.url(forResource: "ShanksSheet", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let sheet = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let frameW = sheet.width / Self.spritesheetFrameCount
        let frameH = sheet.height

        for i in 0..<Self.spritesheetFrameCount {
            let rect = CGRect(x: i * frameW, y: 0, width: frameW, height: frameH)
            if let slice = sheet.cropping(to: rect) {
                frames.append(slice)
            }
        }
    }

    private func loadAsleepSprite() {
        for name in ["ShanksAsleep1", "ShanksAsleep2"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
                  let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            asleepFrames.append(cg)
        }
    }

    func setFrame(_ frame: Frame) {
        if frame == .asleep {
            // Show first asleep frame; caller drives the toggle via setAsleepFrame(:)
            if let img = asleepFrames.first { layer.contents = img }
            return
        }
        let idx = Self.spritesheetIndex[frame] ?? 0
        guard idx < frames.count else { return }
        layer.contents = frames[idx]
    }

    /// Called by the sleep animation timer to alternate between the two asleep frames.
    func setAsleepFrame(_ index: Int) {
        guard !asleepFrames.isEmpty else { return }
        layer.contents = asleepFrames[index % asleepFrames.count]
    }

    func setFlipped(_ flipped: Bool) {
        guard flipped != currentlyFlipped else { return }
        currentlyFlipped = flipped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = flipped
            ? CATransform3DMakeScale(-1, 1, 1)
            : CATransform3DIdentity
        CATransaction.commit()
    }

    func isOpaqueAt(point: CGPoint) -> Bool {
        guard let frame = frames.first,
              let providerData = frame.dataProvider?.data,
              let ptr = CFDataGetBytePtr(providerData) else { return false }

        let scaleX = CGFloat(frame.width)  / displaySize
        let scaleY = CGFloat(frame.height) / displaySize
        let px = Int(point.x * scaleX)
        let py = Int((displaySize - point.y) * scaleY)  // flip Y: AppKit origin is bottom-left

        guard px >= 0, px < frame.width, py >= 0, py < frame.height else { return false }

        let bytesPerPixel = frame.bitsPerPixel / 8
        guard bytesPerPixel > 0 else { return false }
        let offset = py * frame.bytesPerRow + px * bytesPerPixel
        guard offset + bytesPerPixel <= CFDataGetLength(providerData) else { return false }

        // Alpha is the last channel in both RGBA and BGRA
        return ptr[offset + bytesPerPixel - 1] > 32
    }
}
