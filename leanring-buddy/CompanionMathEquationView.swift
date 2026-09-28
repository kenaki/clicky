//
//  CompanionMathEquationView.swift
//  leanring-buddy
//
//  Draws one LaTeX display equation for the transcript panel with SwiftMath,
//  which typesets natively (no web view), so it works inside the panel's
//  click-through, non-activating window. SwiftMath returns a vector-backed
//  NSImage that redraws at any scale. An equation wider than the card is
//  shrunk to fit; one SwiftMath cannot parse shows as raw LaTeX in monospace
//  so nothing Claude wrote is lost.
//
//  Spike: the panel shows a hard-coded sample equation to judge the look on
//  the frosted card. Nothing in the protocol sends equations yet.
//

import AppKit
import SwiftMath
import SwiftUI

struct CompanionMathEquationView: View {
    let latex: String
    let maximumWidth: CGFloat

    /// A little above the 13.5 pt answer text, because math glyphs run small.
    private static let equationFontSize: CGFloat = 16
    /// Rendering again on every SwiftUI body pass would re-parse the LaTeX each
    /// time the speaking sentence changes, so rendered equations are kept.
    private static let renderedEquationImageCache = NSCache<NSString, NSImage>()

    var body: some View {
        if let equationImage = Self.renderedEquationImage(latex: latex) {
            let naturalSize = equationImage.size
            let shrinkToFitFactor = min(1, maximumWidth / max(naturalSize.width, 1))
            Image(nsImage: equationImage)
                .resizable()
                .interpolation(.high)
                .frame(width: naturalSize.width * shrinkToFitFactor, height: naturalSize.height * shrinkToFitFactor)
                .accessibilityLabel(latex)
        } else {
            Text(latex)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Nil when SwiftMath cannot parse the LaTeX, and then it is not cached,
    /// so a broken equation is re-parsed on each pass (cheap, and rare).
    private static func renderedEquationImage(latex: String) -> NSImage? {
        if let cachedEquationImage = renderedEquationImageCache.object(forKey: latex as NSString) {
            return cachedEquationImage
        }
        let mathImage = MTMathImage(
            latex: latex,
            fontSize: equationFontSize,
            textColor: NSColor(DS.Colors.textPrimary),
            labelMode: .display,
            textAlignment: .left
        )
        // Noto Sans sits closer to the panel's SF text than the default Latin Modern textbook face.
        mathImage.font = MTFontManager.manager.notoSansRegularFont(withSize: equationFontSize)
        let (parseError, equationImage) = mathImage.asImage()
        guard parseError == nil, let equationImage else { return nil }
        renderedEquationImageCache.setObject(equationImage, forKey: latex as NSString)
        return equationImage
    }
}

#if DEBUG
/// Spike only: hard-coded equations under every answer, lined up with the
/// sentence text, to judge size, weight, and contrast on the real card. The
/// last one is deliberately broken to show the raw-LaTeX fallback. Remove
/// with the `#if DEBUG` call in CompanionTranscriptPanel.swift.
struct CompanionLatexSpikeSampleEquationRows: View {
    let cardWidth: CGFloat

    private static let sampleEquations: [String] = [
        #"J(\theta) = \frac{1}{2m}\sum_{i=1}^{m} \left(h_\theta(x^{(i)}) - y^{(i)}\right)^2"#,
        #"\theta := \theta - \frac{\alpha}{m} X^{T}\left(X\theta - y\right)"#,
        #"\begin{aligned} f(x) &= (x+1)^2 \\ &= x^2 + 2x + 1 \end{aligned}"#,
        #"\frac{1}{2"#,
    ]
    /// The card's 14 pt padding on both sides, and the speaking bar (3 pt) plus its 8 pt gap.
    private static let horizontalSpaceOutsideEquation: CGFloat = 2 * 14 + 3 + 8

    var body: some View {
        ForEach(Self.sampleEquations, id: \.self) { sampleLatex in
            CompanionMathEquationView(latex: sampleLatex, maximumWidth: cardWidth - Self.horizontalSpaceOutsideEquation)
                .padding(.leading, 3 + 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
