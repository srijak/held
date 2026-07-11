import Foundation

/// YIN pitch detection (de Cheveigné & Kawahara 2002).
/// Difference function -> cumulative mean normalized difference ->
/// absolute threshold -> parabolic interpolation.
/// Identical algorithm to the validated desktop v1 detector.
enum YIN {
    static func detect(
        buffer: [Float],
        sampleRate: Float,
        fMin: Float = 65,
        fMax: Float = 1200,
        threshold: Float = 0.12
    ) -> Float? {
        let n = buffer.count
        guard n >= 512 else { return nil }

        // Silence gate
        var rms: Float = 0
        for s in buffer { rms += s * s }
        rms = (rms / Float(n)).squareRoot()
        guard rms > 0.008 else { return nil }

        let w = n / 2 // integration window
        let tauMin = max(2, Int(sampleRate / fMax))
        let tauMax = min(Int(sampleRate / fMin), n - w - 1)
        guard tauMax > tauMin else { return nil }

        // Difference function
        var d = [Float](repeating: 0, count: tauMax + 1)
        buffer.withUnsafeBufferPointer { p in
            for tau in 1...tauMax {
                var sum: Float = 0
                for i in 0..<w {
                    let diff = p[i] - p[i + tau]
                    sum += diff * diff
                }
                d[tau] = sum
            }
        }

        // Cumulative mean normalized difference
        var cm = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            cm[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        // Absolute threshold: first dip below threshold, walk to local min
        var tauEst = -1
        var tau = tauMin
        while tau <= tauMax {
            if cm[tau] < threshold {
                while tau + 1 <= tauMax && cm[tau + 1] < cm[tau] { tau += 1 }
                tauEst = tau
                break
            }
            tau += 1
        }

        // Fallback: global min, only if reasonably confident
        if tauEst == -1 {
            var minVal = Float.infinity
            var minPos = -1
            for t in tauMin...tauMax where cm[t] < minVal {
                minVal = cm[t]
                minPos = t
            }
            guard minVal < 0.3 else { return nil }
            tauEst = minPos
        }

        // Parabolic interpolation around the estimate
        var tauRefined = Float(tauEst)
        if tauEst > 1 && tauEst < tauMax {
            let x1 = cm[tauEst - 1]
            let x2 = cm[tauEst]
            let x3 = cm[tauEst + 1]
            let a = (x1 + x3 - 2 * x2) / 2
            let b = (x3 - x1) / 2
            if a != 0 { tauRefined = Float(tauEst) - b / (2 * a) }
        }

        let freq = sampleRate / tauRefined
        return (freq >= fMin && freq <= fMax) ? freq : nil
    }
}
