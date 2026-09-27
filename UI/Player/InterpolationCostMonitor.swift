/// Independent windows distinguish sustained overload from a short burst.
/// The caller supplies monotonic time so the policy can be tested deterministically.
struct InterpolationCostMonitor {
    private var windowStart: Double?
    private var totalMS = 0.0
    private var sampleCount = 0
    private var overloadedWindows = 0

    mutating func reset() { self = Self() }

    mutating func record(costMS: Double, budgetMS: Double, now: Double) -> Double? {
        guard costMS.isFinite, costMS >= 0, budgetMS.isFinite, budgetMS > 0,
              now.isFinite else { return nil }
        if windowStart == nil { windowStart = now }
        totalMS += costMS
        sampleCount += 1
        guard let start = windowStart, now - start >= 3 else { return nil }
        let average = totalMS / Double(sampleCount)
        overloadedWindows = average > budgetMS ? overloadedWindows + 1 : 0
        windowStart = now
        totalMS = 0
        sampleCount = 0
        guard overloadedWindows >= 2 else { return nil }
        overloadedWindows = 0
        return average
    }
}
