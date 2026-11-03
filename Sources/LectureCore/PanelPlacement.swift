import Foundation
import CoreGraphics

public enum PanelPlacement {
    /// Keep the whole widget on the display it overlaps most, including after display removal.
    public static func clamped(_ frame: CGRect, to visibleFrames: [CGRect]) -> CGRect {
        guard let first = visibleFrames.first else { return frame }
        let overlapping = visibleFrames.filter { area($0.intersection(frame)) > 0 }
        let screen = overlapping.max { area($0.intersection(frame)) < area($1.intersection(frame)) } ?? first
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
