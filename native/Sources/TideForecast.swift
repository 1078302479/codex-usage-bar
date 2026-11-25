import Foundation

struct TideQuotaHistory {
    struct Sample: Equatable {
        let date: Date
        let remaining: Double
    }

    struct Projection {
        let samples: [Sample]
        let reset: Date
        let exhaustion: Date?
        let remainingAtReset: Double
    }

    private struct Series {
        let reset: Date
        var samples: [Sample]
    }

    private var scope: String?
    private var buckets: [String: Series] = [:]

    mutating func record(_ snapshot: QuotaSnapshot) {
        if scope != snapshot.accountScope { self = Self(); scope = snapshot.accountScope }
        guard scope != nil else { return }
        let date = snapshot.observedAt
        buckets = buckets.filter { key, _ in snapshot.buckets.contains { $0.id == key } }
        for bucket in snapshot.buckets {
            guard let window = bucket.primary, let reset = window.resetDate, date < reset,
                  let remaining = window.remaining else { buckets.removeValue(forKey: bucket.id); continue }
            let previous = buckets[bucket.id]
            if let latest = previous?.samples.last, date <= latest.date { continue }
            var series = previous.flatMap { $0.reset == reset ? $0 : nil } ?? Series(reset: reset, samples: [])
            if let last = series.samples.last {
                // A replenishment breaks the consumption trend, even if the reset timestamp stayed the same.
                if remaining > last.remaining { series.samples.removeAll() }
            }
            series.samples.removeAll { date.timeIntervalSince($0.date) > 18_000 }
            if series.samples.count >= 1_200 { series.samples.removeFirst(series.samples.count - 1_199) }
            series.samples.append(Sample(date: date, remaining: remaining))
            buckets[bucket.id] = series
        }
    }

    func projection(bucket: QuotaBucket?, now: Date) -> Projection? {
        guard let bucket, let series = buckets[bucket.id], series.reset == bucket.primary?.resetDate,
              let last = series.samples.last,
              (0...QuotaPresentation.staleAfter).contains(now.timeIntervalSince(last.date)),
              now < series.reset else { return nil }
        let recent = series.samples.drop { last.date.timeIntervalSince($0.date) > 1800 }
        guard recent.count >= 3, let first = recent.first, last.date.timeIntervalSince(first.date) >= 300 else { return nil }
        let rate = max(0, (first.remaining - last.remaining) / last.date.timeIntervalSince(first.date))
        let secondsToReset = series.reset.timeIntervalSince(last.date)
        let remainingAtReset = max(0, last.remaining - rate * secondsToReset)
        let exhaustion = last.remaining == 0 ? last.date : rate > 0 && last.remaining / rate < secondsToReset
            ? last.date.addingTimeInterval(last.remaining / rate) : nil
        return Projection(samples: series.samples, reset: series.reset, exhaustion: exhaustion,
                          remainingAtReset: remainingAtReset)
    }
}
