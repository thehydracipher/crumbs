// Benchmark: how long scans take on the real apps of this Mac. Changes nothing.
import Foundation
func time<T>(_ f: () -> T) -> (T, Double) { let t = Date(); let r = f(); return (r, Date().timeIntervalSince(t) * 1000) }
let apps = Scanner.installedApps().filter { !$0.isProtected }
var first = 0.0, again = 0.0, full = 0.0
for a in apps {
    let (_, t1) = time { Scanner.scan(a, withSizes: false) }   // list, first time
    let (_, t2) = time { Scanner.scan(a, withSizes: false) }   // list, opened again
    let (_, t3) = time { Scanner.scan(a) }                      // with all sizes
    first += t1; again += t2; full += t3
    print(String(format: "%-20@ list %4.0f ms (again %3.0f ms)   with sizes %5.0f ms", a.displayName as NSString, t1, t2, t3))
}
print(String(format: "TOTAL  list %.0f ms  (again %.0f ms)   with sizes %.0f ms", first, again, full))
