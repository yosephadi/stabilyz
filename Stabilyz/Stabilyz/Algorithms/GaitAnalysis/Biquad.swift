import Foundation

/// A second-order IIR section, used to build the preprocessing band-pass.
///
/// Butterworth response (Q = 1/√2), from the standard bilinear-transform
/// coefficients. Written out rather than pulled from Accelerate because the
/// filter is the part of the pipeline most worth being able to read and check
/// by hand; at 36k samples the cost is irrelevant either way.
struct Biquad: Sendable, Equatable {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    static func lowPass(cutoffHz: Double, sampleRateHz: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoffHz / sampleRateHz
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))

        return Biquad(
            b0: (1 - cosW0) / 2,
            b1: 1 - cosW0,
            b2: (1 - cosW0) / 2,
            a0: 1 + alpha,
            a1: -2 * cosW0,
            a2: 1 - alpha
        )
    }

    static func highPass(cutoffHz: Double, sampleRateHz: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoffHz / sampleRateHz
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))

        return Biquad(
            b0: (1 + cosW0) / 2,
            b1: -(1 + cosW0),
            b2: (1 + cosW0) / 2,
            a0: 1 + alpha,
            a1: -2 * cosW0,
            a2: 1 - alpha
        )
    }

    /// One forward pass. Introduces phase delay; see `filtfilt`.
    func filter(_ input: [Double]) -> [Double] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var output = [Double]()
        output.reserveCapacity(input.count)

        for x in input {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            output.append(y)
        }
        return output
    }

    /// Forward then backward, giving zero phase shift at double the order.
    ///
    /// Every peak stays where it happened, which matters because step times are
    /// measured off this signal and compared against the untouched timeline.
    func filtfilt(_ input: [Double]) -> [Double] {
        guard input.count > 2 else { return input }
        return Array(filter(Array(filter(input).reversed())).reversed())
    }
}
