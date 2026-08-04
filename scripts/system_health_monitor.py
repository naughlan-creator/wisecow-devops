#!/usr/bin/env python3
"""
System health monitor
Checks CPU, memory, disk usages and running process count against thresholds.

Exit codes:
0 all metrics within thresholds
1 one or more thresholds breached
2 the check itself failed to run
"""


import argparse, logging, sys, psutil

DEFAULT_CPU_THRESHOLD = 80.0
DEFAULT_MEM_THRESHOLD = 80.0
DEFAULT_DISK_THRESHOLD = 85.0
DEFAULT_PROC_THRESHOLD = 300
DEFAULT_DISK_PATH = "/"

BYTES_PER_GB = 1024 ** 3

def parse_args():
    """Define and parse commandline arguments"""
    parser = argparse.ArgumentParser(
        description="Monitor Linux system health against thresholds...",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog="Exit code 0 = healthy, 1 = threshold breached, 2 = check failed.",
    )
    parser.add_argument("--cpu", type=float, default=DEFAULT_CPU_THRESHOLD,
                            help="CPU usage alert threshold (%%)")
    parser.add_argument("--memory", type=float, default=DEFAULT_MEM_THRESHOLD,
                            help="Memory usage alert threshold (%%)")
    parser.add_argument("--disk", type=float, default=DEFAULT_DISK_THRESHOLD,
                            help="Disk usage alert threshold (%%)")
    parser.add_argument("--processes", type=int, default=DEFAULT_PROC_THRESHOLD,
                            help="Running process count alert threshold")
    parser.add_argument("--path", default=DEFAULT_DISK_PATH, 
                            help="Filesystem path to check for disk usage")
    parser.add_argument("--log", metavar="FILE", help="Append output to this log file")
    return parser.parse_args()

def setup_logging(logfile=None):
    """Configure logging"""
    handlers = [logging.StreamHandler(sys.stdout)]
    if logfile:
        try:
            handlers.append(logging.FileHandler(logfile))
        except OSError as exc:
            print(f"Warning: could not open {logfile}: {exc}", file=sys.stderr)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
    )

# define the checks

def check_cpu(threshold):
    usage = psutil.cpu_percent(interval=1)
    message = f"CPU usage: {usage:.1f}% (threshold {threshold:.1f}%)"
    return usage > threshold, message

def check_memory(threshold):
    mem = psutil.virtual_memory()
    message = (
        f"Memory usage: {mem.percent:.1f}% "
        f"({mem.used / BYTES_PER_GB:.1f}GB of {mem.total / BYTES_PER_GB:.1f}GB, "
        f"threshold {threshold:.1f}%)"
    )
    return mem.percent > threshold, message

def check_disk(path, threshold):
    disk = psutil.disk_usage(path)
    message = (
        f"Disk usage ({path}): {disk.percent:.1f}% "
        f"({disk.used / BYTES_PER_GB:.1f}GB of {disk.total / BYTES_PER_GB:.1f}GB, "
        f"threshold {threshold:.1f}%)"
    )
    return disk.percent > threshold, message

def check_processes(threshold):
    count = len(psutil.pids())
    message = f"Running processes: {count} (threshold {threshold})"
    return count > threshold, message

def top_processes_by_memory(limit=5):
    procs = []
    for proc in psutil.process_iter(["pid", "name", "memory_percent"]):
        try:
            procs.append(proc.info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    procs.sort(key=lambda p: p.get("memory_percent") or 0.0, reverse=True)
    return procs[:limit]

def main():
    args = parse_args()
    setup_logging(args.log)

    logging.info("=" * 60)
    logging.info("System health check starting")

    try:
        results = [
            check_cpu(args.cpu),
            check_memory(args.memory),
            check_disk(args.path, args.disk),
            check_processes(args.processes),
        ]
    except (psutil.Error, OSError) as exc:
        logging.error("Health check could not complete: %s", exc)
        return 2

    for breached, message in results:
        if breached:
            logging.warning("ALERT  %s", message)
        else:
            logging.info("OK    %s", message)

    any_breached = any(breached for breached, _ in results)

    if any_breached:
        logging.warning("Top processes by memory:")
        for proc in top_processes_by_memory():
            logging.warning(
                "   PID %-8s %-25s %.1f%%",
                proc.get("pid"), proc.get("name"), proc.get("memory_percent") or 0.0,
            )
        logging.warning("Health check FAILED — one or more thresholds breached")
        return 1
    logging.info("Health check PASSED - all metrics within thresholds")
    return 0

    
if __name__ == "__main__":
    sys.exit(main())