#pragma once

#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
  uint64_t cpu_user_ns;
  uint64_t cpu_system_ns;
  uint64_t resident_bytes;
  uint64_t phys_footprint;
} OverlayProcessSample;

/// Snapshots CPU time and memory for `pid`.
/// Returns 0 on success.
int OverlaySampleProcess(pid_t pid, OverlayProcessSample *out);

/// Activity Monitor Energy Impact cumulative score for `pid`'s resource coalition.
/// 10ms of CPU-equivalent work counts as 1. Divide a delta by elapsed seconds to
/// get the rate Activity Monitor shows. Returns 0 on success.
int OverlaySampleEnergyImpact(pid_t pid, double *outScore);

/// Collects `root` plus descendants, processes that name it as responsible,
/// and processes whose executable lives inside `bundlePath` (may be NULL).
/// Returns the number of pids written to `out`.
int OverlayListRelatedPids(pid_t root, const char *bundlePath, pid_t *out, int maxCount);
