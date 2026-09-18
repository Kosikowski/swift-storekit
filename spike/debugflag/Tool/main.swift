import Flag
#if DEBUG
let app = "DEBUG"
#else
let app = "no DEBUG"
#endif
#if SCREENSHOTS
let shots = "SCREENSHOTS"
#else
let shots = "no SCREENSHOTS"
#endif
print("SPIKE app sees: \(app), \(shots) | package sees: \(Flag.packageSees)")
