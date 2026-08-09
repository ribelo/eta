#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[3]
BUNDLE = pathlib.Path(__file__).resolve().parent
BUILD = ROOT / ".scratch" / "eta-crux-bonsai-build" / "bench" / "default"
EXECUTABLES = {
    "eta_crux": BUILD / "eta_adapter.exe",
    "bonsai": BUILD / "bonsai_adapter.exe",
}
EXPECTED_OXCAML = "5.2.0minus38"
EXPECTED_BONSAI = "v0.18~preview.130.100+614"
OX_REPOSITORY_NAME = "eta-crux-bonsai-ox"


def installed_version(package):
    return subprocess.check_output(
        ["opam", "show", package, "--field=installed-version"],
        text=True,
    ).strip()


def installed_packages():
    output = subprocess.check_output(
        [
            "opam",
            "list",
            "--installed",
            "--short",
            "--columns=name,version",
            "--separator=\t",
            "--color=never",
        ],
        text=True,
    )
    packages = {}
    for line in output.splitlines():
        name, version = line.split("\t", 1)
        packages[name.strip()] = version.strip()
    return packages


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def first_cpu_field(name):
    cpuinfo = pathlib.Path("/proc/cpuinfo")
    if not cpuinfo.exists():
        return None
    prefix = name + "\t"
    for line in cpuinfo.read_text().splitlines():
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip()
    return None


def read_optional(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except OSError:
        return None


def git_revision(path):
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def invoke(framework, arguments, cpu):
    command = [str(EXECUTABLES[framework]), *arguments]
    if cpu is not None:
        command = ["taskset", "-c", str(cpu), *command]
    completed = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
    )
    return [json.loads(line) for line in completed.stdout.splitlines() if line]


def workload_names(framework):
    completed = subprocess.run(
        [str(EXECUTABLES[framework]), "--list"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return [line for line in completed.stdout.splitlines() if line]


def percentile(values, percentile_value):
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile_value
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + ((ordered[upper] - ordered[lower]) * fraction)


def distribution(values):
    return {
        "median": statistics.median(values),
        "mean": statistics.fmean(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "p95": percentile(values, 0.95),
        "min": min(values),
        "max": max(values),
    }


def summarize(samples):
    grouped = {}
    for sample in samples:
        key = (sample["workload"], sample["framework"])
        grouped.setdefault(key, []).append(sample)
    rows = []
    metric_names = (
        "wall_ns_per_op",
        "allocated_words_per_op",
        "minor_words_per_op",
        "promoted_words_per_op",
        "major_words_per_op",
        "minor_collections_per_op",
        "major_collections_per_op",
        "compactions_per_op",
    )
    for (workload, framework), values in sorted(grouped.items()):
        row = {
            "workload": workload,
            "framework": framework,
            "samples": len(values),
        }
        for metric_name in metric_names:
            row[metric_name] = distribution(
                [value[metric_name] for value in values]
            )
        rows.append(row)
    ratios = []
    by_workload = {}
    for row in rows:
        by_workload.setdefault(row["workload"], {})[row["framework"]] = row
    for workload, frameworks in sorted(by_workload.items()):
        if set(frameworks) != {"eta_crux", "bonsai"}:
            continue
        eta = frameworks["eta_crux"]
        bonsai = frameworks["bonsai"]
        ratios.append(
            {
                "workload": workload,
                "wall_ratio_eta_over_bonsai": (
                    eta["wall_ns_per_op"]["median"]
                    / bonsai["wall_ns_per_op"]["median"]
                ),
                "allocation_ratio_eta_over_bonsai": (
                    eta["allocated_words_per_op"]["median"]
                    / bonsai["allocated_words_per_op"]["median"]
                    if bonsai["allocated_words_per_op"]["median"] != 0
                    else None
                ),
            }
        )
    return {"rows": rows, "ratios": ratios}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--filter")
    parser.add_argument("--out")
    args = parser.parse_args()
    if not args.quick and args.cpu is None:
        raise SystemExit("full measurements require --cpu")
    if subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--"],
        check=False,
    ).returncode:
        raise SystemExit(
            "tracked Eta sources differ from HEAD; commit or revert them before measuring"
        )

    missing = [str(path) for path in EXECUTABLES.values() if not path.exists()]
    if missing:
        raise SystemExit("missing benchmark executable: " + ", ".join(missing))
    oxcaml_version = installed_version("oxcaml-compiler")
    bonsai_version = installed_version("bonsai")
    if oxcaml_version != EXPECTED_OXCAML:
        raise SystemExit(
            f"expected oxcaml-compiler {EXPECTED_OXCAML}, found {oxcaml_version}"
        )
    if bonsai_version != EXPECTED_BONSAI:
        raise SystemExit(f"expected bonsai {EXPECTED_BONSAI}, found {bonsai_version}")

    eta_names = workload_names("eta_crux")
    bonsai_names = workload_names("bonsai")
    if eta_names != bonsai_names:
        raise SystemExit(
            f"workload lists differ: eta_crux={eta_names}, bonsai={bonsai_names}"
        )
    workloads = eta_names
    if args.filter:
        pattern = re.compile(args.filter)
        workloads = [name for name in workloads if pattern.search(name)]
    if not workloads:
        raise SystemExit("the filter selected no workloads")

    repetitions = 1 if args.quick else 8
    samples_per_process = 1 if args.quick else 2
    warmups = 1 if args.quick else 5
    target_ms = 5.0 if args.quick else 75.0
    all_samples = []
    calibrations = {}
    operation_counts = {}

    for workload in workloads:
        for framework in ("eta_crux", "bonsai"):
            verification_arguments = [
                "--filter",
                f"^{re.escape(workload)}$",
                "--verify",
            ]
            if workload == "startup.root":
                verification_arguments.extend(["--operations", "1"])
            verification = invoke(
                framework, verification_arguments, args.cpu
            )
            if verification != [
                {
                    "kind": "verification",
                    "framework": framework,
                    "workload": workload,
                    "status": "ok",
                }
            ]:
                raise SystemExit(f"verification failed: {verification}")
            calibration = invoke(
                framework,
                [
                    "--filter",
                    f"^{re.escape(workload)}$",
                    "--calibrate",
                    "--target-ms",
                    str(target_ms),
                ],
                args.cpu,
            )
            calibrations[framework] = calibration[0]["operations"]
            operation_counts.setdefault(workload, {})[framework] = calibrations[
                framework
            ]
        schedule = ("eta_crux", "bonsai", "bonsai", "eta_crux")
        for _ in range(repetitions):
            for framework in schedule:
                operations = calibrations[framework]
                records = invoke(
                    framework,
                    [
                        "--filter",
                        f"^{re.escape(workload)}$",
                        "--operations",
                        str(operations),
                        "--samples",
                        str(samples_per_process),
                        "--warmups",
                        str(warmups),
                    ],
                    args.cpu,
                )
                all_samples.extend(records)

    result = {
        "schema_version": 1,
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "eta_commit": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
        ).strip(),
        "eta_status": subprocess.check_output(
            ["git", "-C", str(ROOT), "status", "--short"], text=True
        ).splitlines(),
        "bundle_sha256": {
            name: sha256(BUNDLE / name)
            for name in (
                "README.md",
                "bench_common.ml",
                "bench_common.mli",
                "bonsai_adapter.ml",
                "dune",
                "dune-project",
                "eta_adapter.ml",
                "run.py",
                "run.sh",
                "setup.sh",
            )
        },
        "bonsai_version": bonsai_version,
        "oxcaml_compiler": oxcaml_version,
        "package_versions": installed_packages(),
        "ox_opam_repository_commit": git_revision(
            pathlib.Path(
                subprocess.check_output(["opam", "var", "root"], text=True).strip()
            )
            / "repo"
            / OX_REPOSITORY_NAME
        ),
        "host": {
            "platform": platform.platform(),
            "cpu_model": first_cpu_field("model name"),
            "microcode": first_cpu_field("microcode"),
            "requested_cpu": args.cpu,
            "measured_process_affinity": (
                [args.cpu] if args.cpu is not None else sorted(os.sched_getaffinity(0))
            ),
            "governor": read_optional(
                f"/sys/devices/system/cpu/cpu{args.cpu or 0}/cpufreq/"
                "scaling_governor"
            ),
            "thread_siblings": read_optional(
                f"/sys/devices/system/cpu/cpu{args.cpu or 0}/topology/"
                "thread_siblings_list"
            ),
            "kernel_isolated_cpus": read_optional(
                "/sys/devices/system/cpu/isolated"
            ),
            "boost_enabled": read_optional(
                "/sys/devices/system/cpu/cpufreq/boost"
            ),
            "turbo_disabled": read_optional(
                "/sys/devices/system/cpu/intel_pstate/no_turbo"
            ),
        },
        "quick": args.quick,
        "repetitions": repetitions,
        "samples_per_process": samples_per_process,
        "warmups": warmups,
        "target_ms": target_ms,
        "operation_counts": operation_counts,
        "samples": all_samples,
        "summary": summarize(all_samples),
    }

    if args.out:
        output = pathlib.Path(args.out)
    else:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        output = BUNDLE / "results" / f"{stamp}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
