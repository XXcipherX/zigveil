#!/usr/bin/env python3
"""Barrier coordination, diagnostic deltas, perf parsing and paired statistics."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
import ci
import profiling

BINARY = None
NORMAL = NATIVE = None


class Laboratory(unittest.TestCase):
    def test_required_workloads_fail_when_topology_is_unavailable(self):
        for required in (False, True):
            with self.subTest(required=required), tempfile.TemporaryDirectory() as directory:
                argv = [ci.__file__, "--binary", "/unused/zigveil", "--duration", "1", "--repeats", "1",
                        "--workloads", "bulk:10", "--options", '{"generator_workers":2}', "--output", directory]
                if required:
                    argv.append("--require-workloads")
                with patch.object(sys, "argv", argv), patch.object(os, "sched_getaffinity", return_value={0}), patch.object(
                        ci.collect, "cpu_topology", return_value={}), patch.object(
                        ci.resource, "getrlimit", return_value=(32768, 32768)), patch.dict(os.environ, {}, clear=True), patch(
                        "builtins.print"):
                    status = ci.main()
                self.assertEqual(int(required), status)
                unavailable = json.loads((Path(directory) / "scale-out-unavailable.json").read_text())
                self.assertFalse(unavailable["available"])
                self.assertEqual(required, unavailable["required_workloads"])
                self.assertEqual([], list(Path(directory).glob("*/record.json")))

    def test_production_binary_omits_diagnostic_json(self):
        if NORMAL is None:
            self.skipTest("supply --normal-binary")
        self.assertNotIn(b'{"event":"dataplane"', Path(NORMAL).read_bytes())

    def test_paired_statistics_do_not_substitute_unpaired_medians(self):
        value = ci.paired([1, 10, 100], [2, 11, 100])
        self.assertAlmostEqual(10, value["delta_percent"])
        self.assertEqual(3, value["pairs"])
        self.assertEqual([1., 2.], [x / 100 + 1 for x in value["bootstrap_95_percent"]])
        self.assertIsNone(ci.paired([1, None], [2, 3]))
        self.assertIsNone(ci.spread([1, None]))

    def test_exact_perf_counts_and_unavailable_events_are_distinct(self):
        counts, missing = profiling.parse_stat("123;;cycles;1;100\n<not supported>;;instructions;0;0\n0;;syscalls:sys_enter_close;1;100\n")
        self.assertEqual(123, counts["cycles"])
        self.assertEqual(0, counts["syscalls:sys_enter_close"])
        self.assertNotIn("instructions", counts)
        self.assertIn("instructions", missing)
        self.assertEqual(80, profiling.running_percent("123;;cycles;1;80\n")["cycles"])

    def test_missing_perf_permissions_and_executable_do_not_fail_workloads(self):
        with patch.object(profiling.shutil, "which", return_value="/missing/perf"), patch.object(
                profiling.subprocess, "run", side_effect=FileNotFoundError("perf disappeared")):
            value = profiling.capabilities("perf-stat")
        self.assertFalse(value["available"])
        self.assertIn("disappeared", value["reason"])
        self.assertEqual(dict(kernel_percent=96., user_percent=3., unknown_percent=1.),
                         profiling.dso_split(" 96.00% [kernel.kallsyms]\n 3.00% zigveil\n 1.00% [unknown]\n"))

    def test_summary_separates_baseline_change_observer_effect_and_failed_trials(self):
        records = []
        for variant, rate in (("baseline", 10.), ("candidate", 12.), ("metrics", 11.)):
            for repeat in (1, 2, 3):
                records.append(dict(mode="bulk", concurrency=100, variant=variant, ring=65536,
                                    configured_ring=16384 if variant == "baseline" else 65536, repeat=repeat,
                                    diagnostic_record=False, passed=True, result=dict(echo_goodput_gbit_s=rate)))
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(cases=[("bulk", 100)], rings=[65536], variants=["baseline", "candidate", "metrics"],
                                   repeats=3, output=Path(directory))
            ci.summarize(records, args)
            groups = json.loads((args.output / "summary.json").read_text())
            self.assertEqual(16384, groups[0]["configured_ring"])
            self.assertAlmostEqual(20., groups[1]["vs_baseline"]["echo_goodput_gbit_s"]["delta_percent"])
            self.assertAlmostEqual(-100 / 12., groups[2]["vs_candidate"]["echo_goodput_gbit_s"]["delta_percent"])
            records[3]["passed"] = False
            ci.summarize(records, args)
            failed = json.loads((args.output / "summary.json").read_text())[1]
            self.assertIsNone(failed["metrics"]["echo_goodput_gbit_s"])
            self.assertEqual({}, failed["vs_baseline"])
            self.assertEqual("incomplete / failed", ci.decision(failed))

    def test_wrapping_counters_and_lifetime_gauges(self):
        value = ci.delta(dict(recv_attempts=(1 << 64) - 1, recv_max=65536), dict(event="dataplane", recv_attempts=1, recv_max=65536))
        self.assertEqual(2, value["recv_attempts"])
        self.assertEqual(65536, value["recv_max"])

    def test_multiple_generator_rates_use_a_common_window_and_keep_failures(self):
        a = dict(concurrency=3, valid=True, errors=[], seconds=10., duration_requested_s=10.,
                 bytes_client_to_backend=100, bytes_backend_to_client=100, connections=3,
                 completed_streams=3, max_observed_inflight_bytes_per_stream=256)
        b = dict(a, concurrency=2, connections=2, completed_streams=2)
        windows = [dict(start_ns=0), dict(start_ns=100000000)]
        result = ci.combine_bulk([a, b], windows)
        self.assertEqual(5, result["concurrency"])
        self.assertEqual(5, result["completed_streams"])
        self.assertAlmostEqual(10.1, result["seconds"])
        self.assertAlmostEqual(200 * 8 / 10.1 / 1e9, result["echo_goodput_gbit_s"])
        result = ci.combine_bulk([a, dict(b, valid=False, errors=["corruption"], corruption_events=1)], windows)
        self.assertFalse(result["valid"])
        self.assertIsNone(result["echo_goodput_gbit_s"])
        self.assertEqual(1, result["corruption_events"])

    def test_coordinator_excludes_setup_and_reclaims_connections(self):
        if BINARY is None:
            self.skipTest("supply an instrumented --binary")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(Path(ci.__file__)), "--binary", BINARY, "--metrics-binary", BINARY,
                                     "--duration", "1", "--repeats", "1", "--workloads", "bulk:10,loaded-latency:10,churn:1",
                                     "--profiling", "basic", "--options", '{"variants":["metrics"],"warmup":0.05}',
                                     "--output", directory], capture_output=True, text=True, timeout=60)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            records = [json.loads(p.read_text()) for p in Path(directory).glob("*/record.json")]
            self.assertEqual(3, len(records))
            for record in records:
                self.assertTrue(record["passed"], record)
                self.assertGreater(record["cpu"]["proxy0"]["cpu_seconds"], 0)
                self.assertGreater(record["dataplane"]["drive_calls"], 0)
                self.assertGreater(record["dataplane"]["recv_bytes"] + record["dataplane"].get("splice_read_bytes", 0), 0)
                self.assertEqual(0, record["after_drain"][0]["stats"]["active"])
                self.assertIn(record["after_drain"][0]["proc"]["fds"], record["after_drain"][0]["allowed_idle_fds"])
                if record["mode"] == "bulk":
                    self.assertEqual(0, record["stats_window"][0]["accepted"])
                    self.assertEqual(0, record["stats_window"][0]["routed"])
                    self.assertEqual(record["result"]["bytes_client_to_backend"], record["result"]["bytes_backend_to_client"])

    def test_native_tool_preserves_thousand_streams_and_interoperates_with_python(self):
        if NATIVE is None or BINARY is None:
            self.skipTest("supply --native-binary and --binary")
        for options in ('{"variants":["metrics"],"warmup":0.05}',
                        '{"variants":["metrics"],"warmup":0.05,"origin":"python"}',
                        '{"variants":["metrics"],"warmup":0.05,"generator":"python"}',
                        '{"variants":["metrics"],"warmup":0.05,"generator_workers":2,"origin_io":"splice"}'):
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([sys.executable, str(Path(ci.__file__)), "--binary", BINARY, "--metrics-binary", BINARY,
                                         "--native-binary", NATIVE, "--duration", "1", "--repeats", "1",
                                         "--workloads", "bulk:1000,loaded-latency:10", "--profiling", "basic",
                                         "--options", options, "--output", directory], capture_output=True, text=True, timeout=60)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                for path in Path(directory).glob("*/record.json"):
                    record = json.loads(path.read_text())
                    self.assertTrue(record["passed"], record)
                    self.assertEqual(0, record["result"]["corruption_events"])
                    self.assertEqual(record["result"]["bytes_client_to_backend"], record["result"]["bytes_backend_to_client"])
                    self.assertLessEqual(record["result"]["max_observed_inflight_bytes_per_stream"], 262144)
                    self.assertEqual(0, record["after_drain"][0]["stats"]["active"])
                    if len(record["generator_results"]) == 2:
                        self.assertEqual(2, len(record["generator_exit_codes"]))
                        self.assertEqual(record["concurrency"], sum(r["concurrency"] for r in record["generator_results"]))
                        self.assertEqual(record["result"]["bytes_client_to_backend"],
                                         sum(r["bytes_client_to_backend"] for r in record["generator_results"]) +
                                         record.get("probe_result", {}).get("bytes_client_to_backend", 0))
                    if json.loads(options).get("origin_io") == "splice":
                        self.assertIn(record["origin_ready"]["echo_io"], ("shared-splice", "buffered"))

    def test_reuseport_pair_uses_distinct_proxy_cpus_and_reclaims_each_process(self):
        if BINARY is None or NATIVE is None or len(os.sched_getaffinity(0)) < 4:
            self.skipTest("supply native tools on four CPUs")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(Path(ci.__file__)), "--binary", BINARY, "--baseline", BINARY,
                                     "--metrics-binary", BINARY, "--native-binary", NATIVE, "--processes", "2",
                                     "--duration", "1", "--repeats", "1", "--workloads", "bulk:100", "--profiling", "basic",
                                     "--options", '{"variants":["baseline","metrics"],"baseline_processes":1,"warmup":0.05}',
                                     "--output", directory], capture_output=True, text=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            records = {r["variant"]: r for r in (json.loads(p.read_text()) for p in Path(directory).glob("*/record.json"))}
            self.assertEqual(1, records["baseline"]["process_count"])
            self.assertEqual(2, records["metrics"]["process_count"])
            self.assertEqual(4, len(set(records["metrics"]["affinity"].values())))
            self.assertEqual(records["baseline"]["affinity"]["generator"], records["metrics"]["affinity"]["generator"])
            for record in records.values():
                self.assertTrue(record["passed"], record)
                self.assertTrue(all(s["stats"]["active"] == 0 and s["proc"]["fds"] in s["allowed_idle_fds"] for s in record["after_drain"]))

    def test_normal_baseline_reclaims_shared_fds_without_diagnostic_snapshot(self):
        if NORMAL is None or NATIVE is None:
            self.skipTest("supply --normal-binary and --native-binary")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(Path(ci.__file__)), "--binary", NORMAL, "--baseline", NORMAL,
                                     "--native-binary", NATIVE, "--duration", "1", "--repeats", "1",
                                     "--workloads", "bulk:10", "--profiling", "basic",
                                     "--options", '{"variants":["baseline","candidate"],"warmup":0.05}',
                                     "--output", directory], capture_output=True, text=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            records = [json.loads(p.read_text()) for p in Path(directory).glob("*/record.json")]
            self.assertEqual({"baseline", "candidate"}, {r["variant"] for r in records})
            for record in records:
                self.assertTrue(record["passed"], record)
                self.assertNotIn("dataplane", record)
                drained = record["after_drain"][0]
                self.assertEqual(0, drained["stats"]["active"])
                self.assertEqual(drained["stats"]["accepted"], drained["stats"]["closed"])
                self.assertEqual(10, drained["proc"]["fds"], "exercise an allocated shared pair in the ordinary build")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary")
    parser.add_argument("--normal-binary")
    parser.add_argument("--native-binary")
    options = parser.parse_args()
    BINARY = str(Path(options.binary).resolve()) if options.binary else None
    NORMAL = str(Path(options.normal_binary).resolve()) if options.normal_binary else None
    NATIVE = str(Path(options.native_binary).resolve()) if options.native_binary else None
    unittest.main(argv=[sys.argv[0]], verbosity=2)
