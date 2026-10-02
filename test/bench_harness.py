#!/usr/bin/env python3
"""Benchmark flow control, failure reporting and production relay regressions."""
import argparse
import asyncio
from contextlib import asynccontextmanager
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))
import harness
import integration

BINARY = None


def arguments(port, **overrides):
    values = dict(host="127.0.0.1", port=port, sni="example.com", mode="bulk",
                  duration=.15, concurrency=2, chunk_bytes=4096,
                  inflight_bytes=16384, drain_timeout=2)
    values.update(overrides)
    return argparse.Namespace(**values)


@asynccontextmanager
async def origin(handler):
    workers = set()
    writers = set()
    failures = []

    async def serve(reader, writer):
        task = asyncio.current_task()
        workers.add(task)
        writers.add(writer)
        failed = False
        try:
            await handler(reader, writer)
        except (OSError, asyncio.CancelledError):
            failed = True
        except BaseException as exc:
            failed = True
            failures.append(exc)
        finally:
            await harness.close_writer(writer, abort=failed)
            writers.discard(writer)
            workers.discard(task)

    server = await asyncio.start_server(serve, "127.0.0.1", 0, backlog=4096)
    try:
        yield server.sockets[0].getsockname()[1]
    finally:
        server.close()
        # Newer Python versions wait for active server transports here too.
        # Release held connections before joining the server, including peers
        # intentionally withholding EOF in the cancellation/timeout fixtures.
        for writer in writers:
            writer.transport.abort()
        pending = list(workers)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        await server.wait_closed()
        if failures:
            raise AssertionError(failures)


async def stalled_echo(reader, writer):
    wire = harness.client_hello("example.com")
    assert await reader.readexactly(len(wire)) == wire
    writer.write(wire)
    await writer.drain()
    while await reader.read(65536):
        pass
    # Deliberately withhold echoed payload and EOF after client FIN.
    await asyncio.Event().wait()


class Harness(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.watchdog = asyncio.get_running_loop().call_later(20, self.dump_pending_tasks)

    def dump_pending_tasks(self):
        print(f"Pending tasks in {self._testMethodName}:", file=sys.stderr, flush=True)
        for task in asyncio.all_tasks():
            print(repr(task), file=sys.stderr, flush=True)
            task.print_stack(file=sys.stderr)

    async def asyncTearDown(self):
        self.watchdog.cancel()

    def assert_valid_bulk(self, result, streams, window):
        self.assertTrue(result["valid"], result)
        self.assertFalse(result["timed_out"], result)
        self.assertEqual([], result["errors"])
        self.assertEqual(streams, result["connections"])
        self.assertGreater(result["bytes_client_to_backend"], 0)
        self.assertEqual(result["bytes_client_to_backend"], result["bytes_backend_to_client"])
        self.assertLessEqual(result["max_observed_inflight_bytes_per_stream"], window)
        self.assertEqual(window, result["inflight_bytes_per_stream"])

    async def test_bounded_pipeline_with_delayed_echo_and_fin(self):
        async def delayed(reader, writer):
            while chunk := await reader.read(4096):
                await asyncio.sleep(.002)
                writer.write(chunk)
                await writer.drain()
            writer.write_eof()
            await writer.drain()
        async with origin(delayed) as port:
            result = await harness.run(arguments(port))
        self.assert_valid_bulk(result, 2, 16384)

    async def test_stalled_echo_returns_partial_counters_without_rates(self):
        async with origin(stalled_echo) as port:
            result = await asyncio.wait_for(harness.run(arguments(port, duration=.1, drain_timeout=.1)), 5)
        self.assertFalse(result["valid"])
        self.assertTrue(result["timed_out"])
        self.assertEqual(2, result["unfinished_workers"])
        self.assertEqual(2, result["error_count"])
        self.assertEqual(0, result["connections"])
        self.assertEqual(0, result["bytes_backend_to_client"])
        self.assertGreater(result["bytes_client_to_backend"], 0)
        self.assertLessEqual(result["bytes_client_to_backend"], 2 * 16384)
        self.assertIsNone(result["echo_goodput_gbit_s"])
        self.assertIsNone(result["aggregate_forwarded_gbit_s"])
        self.assertEqual(1, len(result["errors"]))

    async def test_timeout_cli_is_json_and_exits_nonzero(self):
        async with origin(stalled_echo) as port:
            process = await asyncio.create_subprocess_exec(
                sys.executable, harness.__file__, "run", "--port", str(port),
                "--duration", ".1", "--drain-timeout", ".1",
                "--chunk-bytes", "4096", "--inflight-bytes", "16384",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                stdout, stderr = await asyncio.wait_for(process.communicate(), 5)
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()
        result = json.loads(stdout)
        self.assertEqual(1, process.returncode)
        self.assertTrue(result["timed_out"])
        self.assertNotIn(b"Traceback", stderr)

    async def test_early_eof_is_a_failed_measurement(self):
        async def early_eof(reader, writer):
            wire = harness.client_hello("example.com")
            await reader.readexactly(len(wire))
            writer.write(wire)
            await writer.drain()
            writer.write_eof()
        async with origin(early_eof) as port:
            result = await harness.run(arguments(port, concurrency=1))
        self.assertFalse(result["valid"])
        self.assertTrue(result["errors"])
        self.assertIsNone(result["aggregate_forwarded_gbit_s"])

    async def test_cancellation_cleans_up_sender_tasks(self):
        async with origin(stalled_echo) as port:
            task = asyncio.create_task(harness.run(arguments(port, duration=60)))
            await asyncio.sleep(.1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(task, 5)
            await asyncio.sleep(0)
            leaked = [task for task in asyncio.all_tasks() if "bulk.<locals>.send" in task.get_coro().__qualname__]
            self.assertEqual([], leaked)

    async def test_close_deadline_aborts_a_transport_that_never_closes(self):
        class Writer:
            def __init__(self):
                self.transport = self
                self.aborted = False
            def close(self):
                pass
            def abort(self):
                self.aborted = True
            async def wait_closed(self):
                await asyncio.Event().wait()
        writer = Writer()
        await asyncio.wait_for(harness.close_writer(writer, timeout=.01), 1)
        self.assertTrue(writer.aborted)

    async def test_latency_and_churn_keep_valid_results(self):
        async with origin(harness.echo) as port:
            for mode in ("latency", "churn"):
                result = await harness.run(arguments(port, mode=mode))
                self.assertTrue(result["valid"], result)
                self.assertEqual([], result["errors"])
                self.assertGreater(result["connections"], 0)
                self.assertGreater(result["round_trips"], 0)

    async def test_invalid_window_and_nonfinite_time_are_rejected(self):
        for options in (("--chunk-bytes", "65536", "--inflight-bytes", "4096"),
                        ("--drain-timeout", "nan"), ("--duration", "inf")):
            process = await asyncio.create_subprocess_exec(
                sys.executable, harness.__file__, "run", *options,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            stdout, stderr = await process.communicate()
            self.assertEqual(2, process.returncode)
            self.assertEqual(b"", stdout)
            self.assertIn(b"error:", stderr)

    async def test_thousand_streams_through_production_proxy_drain_cleanly(self):
        if BINARY is None:
            self.skipTest("supply --binary for the Linux production relay regression")
        integration.BINARY = BINARY
        # Match the command-line harness rather than debug instrumentation of
        # every Python callback, which is not part of the workload under test.
        asyncio.get_running_loop().set_debug(False)
        async with origin(harness.echo) as port:
            with integration.Daemon(f"127.0.0.1:{port}", max_connections=2048, max_handshakes=64,
                                    relay_buffer_bytes=16384, idle_timeout_ms=0) as proxy:
                result = await asyncio.wait_for(harness.run(arguments(
                    proxy.port, concurrency=1000, duration=.5, chunk_bytes=65536,
                    inflight_bytes=262144, drain_timeout=15)), 60)
                self.assert_valid_bulk(result, 1000, 262144)
                proxy.wait_for(lambda: proxy.snapshot()["active"] == 0)
                counts = proxy.snapshot()
                self.assertEqual(1000, counts["accepted"])
                self.assertEqual(1000, counts["closed"])
                self.assertEqual(0, counts["io_errors"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary")
    options = parser.parse_args()
    BINARY = str(Path(options.binary).resolve()) if options.binary else None
    unittest.main(argv=[sys.argv[0]], verbosity=2)
