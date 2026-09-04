#include "ProcessSampler.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);

static uint64_t OverlayMachToNs(uint64_t value) {
  static mach_timebase_info_data_t timebase;
  static bool timebaseReady = false;
  if (!timebaseReady) {
    mach_timebase_info(&timebase);
    timebaseReady = true;
  }
  return value * timebase.numer / timebase.denom;
}

static pid_t OverlayResponsiblePid(pid_t pid) {
  pid_t responsible = responsibility_get_pid_responsible_for_pid(pid);
  if (responsible <= 0) {
    return pid;
  }
  return responsible;
}

static bool OverlayContainsPid(const pid_t *pids, int count, pid_t pid) {
  for (int i = 0; i < count; i++) {
    if (pids[i] == pid) {
      return true;
    }
  }
  return false;
}

static bool OverlayPathIsInsideBundle(const char *path, const char *bundlePath) {
  if (path == NULL || bundlePath == NULL || bundlePath[0] == '\0') {
    return false;
  }
  size_t bundleLength = strlen(bundlePath);
  if (strncmp(path, bundlePath, bundleLength) != 0) {
    return false;
  }
  return path[bundleLength] == '\0' || path[bundleLength] == '/';
}

int OverlaySampleProcess(pid_t pid, OverlayProcessSample *out) {
  if (out == NULL) {
    return -1;
  }
  memset(out, 0, sizeof(*out));

  struct rusage_info_v6 usage6;
  memset(&usage6, 0, sizeof(usage6));
  if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage6) == 0) {
    out->cpu_user_ns = OverlayMachToNs(usage6.ri_user_time);
    out->cpu_system_ns = OverlayMachToNs(usage6.ri_system_time);
    out->resident_bytes = usage6.ri_resident_size;
    out->phys_footprint = usage6.ri_phys_footprint;
    return 0;
  }

  struct rusage_info_v4 usage4;
  memset(&usage4, 0, sizeof(usage4));
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage4) == 0) {
    out->cpu_user_ns = OverlayMachToNs(usage4.ri_user_time);
    out->cpu_system_ns = OverlayMachToNs(usage4.ri_system_time);
    out->resident_bytes = usage4.ri_resident_size;
    out->phys_footprint = usage4.ri_phys_footprint;
    return 0;
  }

  struct proc_taskinfo taskInfo;
  memset(&taskInfo, 0, sizeof(taskInfo));
  int bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, (int)sizeof(taskInfo));
  if (bytes != (int)sizeof(taskInfo)) {
    return -1;
  }

  out->cpu_user_ns = OverlayMachToNs(taskInfo.pti_total_user);
  out->cpu_system_ns = OverlayMachToNs(taskInfo.pti_total_system);
  out->resident_bytes = taskInfo.pti_resident_size;
  out->phys_footprint = taskInfo.pti_resident_size;
  return 0;
}

int OverlayListRelatedPids(pid_t root, const char *bundlePath, pid_t *out, int maxCount) {
  if (out == NULL || maxCount <= 0 || root <= 0) {
    return 0;
  }

  pid_t collected[512];
  const int collectedCap = (int)(sizeof(collected) / sizeof(collected[0]));
  int count = 0;
  collected[count++] = root;

  pid_t allPids[4096];
  int allCount = 0;
  int listBytes = proc_listallpids(allPids, (int)sizeof(allPids));
  if (listBytes > 0) {
    allCount = listBytes / (int)sizeof(pid_t);
  }

  int previousCount = 0;
  for (int pass = 0; pass < 6 && previousCount != count && count < collectedCap; pass++) {
    previousCount = count;

    for (int index = 0; index < count && count < collectedCap; index++) {
      pid_t children[256];
      int bytes = proc_listchildpids(collected[index], children, (int)sizeof(children));
      if (bytes <= 0) {
        continue;
      }
      int childCount = bytes / (int)sizeof(pid_t);
      for (int childIndex = 0; childIndex < childCount && count < collectedCap; childIndex++) {
        pid_t child = children[childIndex];
        if (child <= 0 || OverlayContainsPid(collected, count, child)) {
          continue;
        }
        collected[count++] = child;
      }
    }

    for (int index = 0; index < allCount && count < collectedCap; index++) {
      pid_t pid = allPids[index];
      if (pid <= 1 || OverlayContainsPid(collected, count, pid)) {
        continue;
      }

      bool related = false;
      pid_t responsible = OverlayResponsiblePid(pid);
      if (responsible > 1 && OverlayContainsPid(collected, count, responsible)) {
        related = true;
      }

      if (!related && bundlePath != NULL) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof(path)) > 0 && OverlayPathIsInsideBundle(path, bundlePath)) {
          related = true;
        }
      }

      if (related) {
        collected[count++] = pid;
      }
    }
  }

  int copyCount = count < maxCount ? count : maxCount;
  memcpy(out, collected, (size_t)copyCount * sizeof(pid_t));
  return copyCount;
}

#define OVERLAY_COALITION_TYPE_RESOURCE 0
#define OVERLAY_COALITION_NUM_TYPES 2
#define OVERLAY_COALITION_NUM_THREAD_QOS_TYPES 7
#define OVERLAY_PROC_PIDCOALITIONINFO 20
#define OVERLAY_THREAD_QOS_UNSPECIFIED 0
#define OVERLAY_THREAD_QOS_BACKGROUND 2
#define OVERLAY_THREAD_QOS_UTILITY 3
#define OVERLAY_THREAD_QOS_LEGACY 4
#define OVERLAY_THREAD_QOS_USER_INITIATED 5
#define OVERLAY_THREAD_QOS_USER_INTERACTIVE 6
#define OVERLAY_NS_PER_SEC 1000000000.0
#define OVERLAY_NS_TO_EI 1e-7

struct OverlayProcPidCoalitionInfo {
  uint64_t coalition_id[OVERLAY_COALITION_NUM_TYPES];
  uint64_t reserved1;
  uint64_t reserved2;
  uint64_t reserved3;
};

struct OverlayCoalitionUsage {
  uint64_t tasks_started;
  uint64_t tasks_exited;
  uint64_t time_nonempty;
  uint64_t cpu_time;
  uint64_t interrupt_wakeups;
  uint64_t platform_idle_wakeups;
  uint64_t bytesread;
  uint64_t byteswritten;
  uint64_t gpu_time;
  uint64_t cpu_time_billed_to_me;
  uint64_t cpu_time_billed_to_others;
  uint64_t energy;
  uint64_t logical_immediate_writes;
  uint64_t logical_deferred_writes;
  uint64_t logical_invalidated_writes;
  uint64_t logical_metadata_writes;
  uint64_t logical_immediate_writes_to_external;
  uint64_t logical_deferred_writes_to_external;
  uint64_t logical_invalidated_writes_to_external;
  uint64_t logical_metadata_writes_to_external;
  uint64_t energy_billed_to_me;
  uint64_t energy_billed_to_others;
  uint64_t cpu_ptime;
  uint64_t cpu_time_eqos_len;
  uint64_t cpu_time_eqos[OVERLAY_COALITION_NUM_THREAD_QOS_TYPES];
  uint64_t cpu_instructions;
  uint64_t cpu_cycles;
  uint64_t fs_metadata_writes;
  uint64_t pm_writes;
  uint64_t cpu_pinstructions;
  uint64_t cpu_pcycles;
  uint64_t conclave_mem;
  uint64_t ane_mach_time;
  uint64_t ane_energy_nj;
  uint64_t phys_footprint;
  uint64_t gpu_energy_nj;
  uint64_t gpu_energy_nj_billed_to_me;
  uint64_t gpu_energy_nj_billed_to_others;
  uint64_t swapins;
};

struct OverlayEnergyCoefficients {
  double kcpu_wakeups;
  double kqos_default;
  double kqos_background;
  double kqos_utility;
  double kqos_legacy;
  double kqos_user_initiated;
  double kqos_user_interactive;
  double kdiskio_bytesread;
  double kdiskio_byteswritten;
  double kgpu_time;
};

extern int coalition_info_resource_usage(uint64_t cid, struct OverlayCoalitionUsage *cru, size_t sz);

static double OverlayPlistNumber(CFDictionaryRef dict, CFStringRef key) {
  if (dict == NULL) {
    return 0;
  }
  CFTypeRef value = CFDictionaryGetValue(dict, key);
  if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
    return 0;
  }
  double number = 0;
  CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
  return number;
}

static bool OverlayReadCoefficientsAtPath(const char *path, struct OverlayEnergyCoefficients *out) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    return false;
  }
  struct stat info;
  if (fstat(fd, &info) != 0 || info.st_size <= 0) {
    close(fd);
    return false;
  }
  void *bytes = malloc((size_t)info.st_size);
  if (bytes == NULL) {
    close(fd);
    return false;
  }
  ssize_t readCount = read(fd, bytes, (size_t)info.st_size);
  close(fd);
  if (readCount != info.st_size) {
    free(bytes);
    return false;
  }

  CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, (CFIndex)readCount, kCFAllocatorMalloc);
  if (data == NULL) {
    free(bytes);
    return false;
  }
  CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
  CFRelease(data);
  if (plist == NULL || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
    if (plist != NULL) {
      CFRelease(plist);
    }
    return false;
  }

  CFDictionaryRef root = plist;
  CFTypeRef constantsValue = CFDictionaryGetValue(root, CFSTR("energy_constants"));
  if (constantsValue == NULL || CFGetTypeID(constantsValue) != CFDictionaryGetTypeID()) {
    CFRelease(plist);
    return false;
  }
  CFDictionaryRef constants = constantsValue;

  memset(out, 0, sizeof(*out));
  out->kcpu_wakeups = OverlayPlistNumber(constants, CFSTR("kcpu_wakeups"));
  out->kqos_default = OverlayPlistNumber(constants, CFSTR("kqos_default"));
  out->kqos_background = OverlayPlistNumber(constants, CFSTR("kqos_background"));
  out->kqos_utility = OverlayPlistNumber(constants, CFSTR("kqos_utility"));
  out->kqos_legacy = OverlayPlistNumber(constants, CFSTR("kqos_legacy"));
  out->kqos_user_initiated = OverlayPlistNumber(constants, CFSTR("kqos_user_initiated"));
  out->kqos_user_interactive = OverlayPlistNumber(constants, CFSTR("kqos_user_interactive"));
  out->kdiskio_bytesread = OverlayPlistNumber(constants, CFSTR("kdiskio_bytesread"));
  out->kdiskio_byteswritten = OverlayPlistNumber(constants, CFSTR("kdiskio_byteswritten"));
  out->kgpu_time = OverlayPlistNumber(constants, CFSTR("kgpu_time"));
  CFRelease(plist);
  return true;
}

static bool OverlayBoardId(char *out, size_t outSize) {
  io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
  if (service == IO_OBJECT_NULL) {
    return false;
  }
  CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("board-id"), kCFAllocatorDefault, 0);
  IOObjectRelease(service);
  if (value == NULL || CFGetTypeID(value) != CFDataGetTypeID()) {
    if (value != NULL) {
      CFRelease(value);
    }
    return false;
  }
  CFDataRef data = value;
  CFIndex length = CFDataGetLength(data);
  if (length <= 0 || (size_t)length >= outSize) {
    CFRelease(value);
    return false;
  }
  memcpy(out, CFDataGetBytePtr(data), (size_t)length);
  out[length] = '\0';
  CFRelease(value);
  return out[0] != '\0';
}

static const struct OverlayEnergyCoefficients *OverlayEnergyCoefficients(void) {
  static struct OverlayEnergyCoefficients coefficients;
  static bool loaded = false;
  if (loaded) {
    return &coefficients;
  }

  char boardId[128];
  char path[256];
  if (OverlayBoardId(boardId, sizeof(boardId))) {
    snprintf(path, sizeof(path), "/usr/share/pmenergy/%s.plist", boardId);
    if (OverlayReadCoefficientsAtPath(path, &coefficients)) {
      loaded = true;
      return &coefficients;
    }
  }

  if (!OverlayReadCoefficientsAtPath("/usr/share/pmenergy/default.plist", &coefficients)) {
    memset(&coefficients, 0, sizeof(coefficients));
    coefficients.kcpu_wakeups = 0.0002;
    coefficients.kqos_default = 1;
    coefficients.kqos_background = 0.8;
    coefficients.kqos_utility = 1;
    coefficients.kqos_legacy = 1;
    coefficients.kqos_user_initiated = 1;
    coefficients.kqos_user_interactive = 1;
  }
  loaded = true;
  return &coefficients;
}

static double OverlayEnergyImpactScore(const struct OverlayCoalitionUsage *usage) {
  const struct OverlayEnergyCoefficients *coefficients = OverlayEnergyCoefficients();
  double cpuTimeEquivalentNs = 0;
  cpuTimeEquivalentNs += coefficients->kcpu_wakeups * OVERLAY_NS_PER_SEC * (double)usage->platform_idle_wakeups;
  cpuTimeEquivalentNs += coefficients->kgpu_time * (double)OverlayMachToNs(usage->gpu_time);
  cpuTimeEquivalentNs += coefficients->kqos_default * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_UNSPECIFIED]);
  cpuTimeEquivalentNs += coefficients->kqos_background * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_BACKGROUND]);
  cpuTimeEquivalentNs += coefficients->kqos_utility * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_UTILITY]);
  cpuTimeEquivalentNs += coefficients->kqos_legacy * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_LEGACY]);
  cpuTimeEquivalentNs += coefficients->kqos_user_initiated * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_USER_INITIATED]);
  cpuTimeEquivalentNs += coefficients->kqos_user_interactive * (double)OverlayMachToNs(usage->cpu_time_eqos[OVERLAY_THREAD_QOS_USER_INTERACTIVE]);
  cpuTimeEquivalentNs += coefficients->kdiskio_bytesread * OVERLAY_NS_PER_SEC * (double)usage->bytesread;
  cpuTimeEquivalentNs += coefficients->kdiskio_byteswritten * OVERLAY_NS_PER_SEC * (double)usage->byteswritten;
  return cpuTimeEquivalentNs * OVERLAY_NS_TO_EI;
}

static int OverlayCopyCoalitionUsage(pid_t pid, struct OverlayCoalitionUsage *out) {
  struct OverlayProcPidCoalitionInfo info;
  memset(&info, 0, sizeof(info));
  int bytes = proc_pidinfo(pid, OVERLAY_PROC_PIDCOALITIONINFO, 0, &info, (int)sizeof(info));
  if (bytes != (int)sizeof(info)) {
    return -1;
  }

  uint64_t coalitionId = info.coalition_id[OVERLAY_COALITION_TYPE_RESOURCE];
  if (coalitionId == 0) {
    return -1;
  }

  memset(out, 0, sizeof(*out));
  if (coalition_info_resource_usage(coalitionId, out, sizeof(*out)) != 0) {
    return -1;
  }
  return 0;
}

int OverlaySampleEnergyImpact(pid_t pid, double *outScore) {
  if (outScore == NULL || pid <= 0) {
    return -1;
  }

  struct OverlayCoalitionUsage usage;
  if (OverlayCopyCoalitionUsage(pid, &usage) != 0) {
    return -1;
  }

  *outScore = OverlayEnergyImpactScore(&usage);
  return 0;
}
