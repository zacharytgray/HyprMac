// Cross-module shared tunables. Subsystem-local values stay in their
// own files (`TilingConfig`, file-private `enum Tuning`, etc.).

import Foundation

/// Cross-module tunables. Every constant added here carries a comment
/// noting its origin (empirical / computed / OS-imposed) and the
/// effect of changing it. Empty so far — values land here when a
/// constant genuinely needs to leak across module boundaries.
enum Constants {}
