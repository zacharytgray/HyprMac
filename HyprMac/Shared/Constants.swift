import Foundation

// global tunables shared across subsystems.
// per §5.1 of REFACTOR_PLAN.md, this is the home for values that leak across module boundaries
// (poll interval, default suppression durations, app-wide UI timings).
//
// subsystem-local constants stay in their own files (TilingConfig.swift, file-private enum Tuning, etc.).
// every constant added here must carry a comment noting its origin (empirical / computed / OS-imposed)
// and the effect of changing it.
//
// placeholder — populated incrementally during later phases as constants are extracted.
enum Constants {}
