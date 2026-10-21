// Word range -> screen rect via AX (direct bounds, node map), ported from ReadAlong. Stub; owned by WP4.
import CoreGraphics
import Foundation

protocol WordLocator {
    /// Screen rect for the UTF-16 source range, or nil (never a guess).
    func rect(forWord range: Range<Int>) -> CGRect?
}
