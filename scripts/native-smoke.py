#!/usr/bin/env python3
"""Check native fixture observations against the installed manager's CLI."""

import argparse
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import traceback


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def close_frame(actual, expected, tolerance=3):
    return all(
        abs(actual[field] - expected[field]) <= tolerance
        for field in ("left", "top", "width", "height")
    )


def contains(bounds, frame, inset=0, tolerance=3):
    return (
        frame["left"] >= bounds["left"] + inset - tolerance
        and frame["top"] >= bounds["top"] + inset - tolerance
        and frame["left"] + frame["width"]
        <= bounds["left"] + bounds["width"] - inset + tolerance
        and frame["top"] + frame["height"]
        <= bounds["top"] + bounds["height"] - inset + tolerance
    )


def overlaps(first, second, tolerance=3):
    return (
        min(first["left"] + first["width"], second["left"] + second["width"])
        - max(first["left"], second["left"])
        > tolerance
        and min(first["top"] + first["height"], second["top"] + second["height"])
        - max(first["top"], second["top"])
        > tolerance
    )


def frames(report):
    return {window["title"]: window["frame"] for window in report["windows"]}


def key_title(report):
    return next(
        (window["title"] for window in report["windows"] if window["key"]), None
    )


def process_ids(name):
    result = subprocess.run(
        ["pgrep", "-x", name], capture_output=True, text=True, check=False
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(f"Cannot inspect processes for {name}: {result.stderr}")
    return [int(value) for value in result.stdout.split()]


class NativeSmoke:
    def __init__(self, arguments):
        self.arguments = arguments
        self.output = arguments.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.binary = arguments.app.resolve() / "Contents/MacOS/huen-wm"
        self.report_path = self.output / "fixture.json"
        self.config_path = self.output / "config.lua"
        self.result = {
            "passed": False,
            "checks": [],
            "commands": [],
            "snapshots": {},
            "cleanup_errors": [],
            "scenes": arguments.scenes,
        }
        self.fixture_pid = None
        self.manager_started = False
        self.aerospace_changed = False
        self.aerospace = shutil.which("aerospace")

    def run_command(self, command, required=True):
        completed = subprocess.run(
            [str(part) for part in command],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.result["commands"].append(
            {
                "argv": [str(part) for part in command],
                "returncode": completed.returncode,
                "stdout": completed.stdout,
                "stderr": completed.stderr,
            }
        )
        if required and completed.returncode:
            raise RuntimeError(
                f"Command failed: {command}: {completed.stderr or completed.stdout}"
            )
        return completed

    def cli(self, *arguments, required=True):
        completed = self.run_command([self.binary, *arguments], required=required)
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError:
            if required:
                raise RuntimeError(f"No JSON from {arguments}: {completed.stdout}")
            return None
        if required and isinstance(response, dict) and response.get("error"):
            raise RuntimeError(f"CLI rejected {arguments}: {response}")
        return response

    def launch(self, application, label, *arguments, foreground=False):
        self.run_command(
            [
                "open",
                "-n",
                *([] if foreground else ["-g"]),
                "-a",
                application,
                "--stdout",
                self.output / f"{label}.stdout.log",
                "--stderr",
                self.output / f"{label}.stderr.log",
                "--args",
                *arguments,
            ]
        )

    def wait(self, name, observe, predicate, healthy=True):
        deadline = time.monotonic() + self.arguments.timeout
        last = None
        stable_since = None
        while time.monotonic() < deadline:
            last = observe()
            if healthy and self.manager_started:
                self.health()
            if last is not None and predicate(last):
                if stable_since is None:
                    stable_since = time.monotonic()
                if time.monotonic() - stable_since >= 0.35:
                    self.result["checks"].append({"name": name, "passed": True})
                    self.result["snapshots"][name] = last
                    print(f"PASS {name}", flush=True)
                    return last
            else:
                stable_since = None
            time.sleep(0.08)
        self.result["checks"].append({"name": name, "passed": False, "last": last})
        raise RuntimeError(f"Timed out: {name}; last observation: {last}")

    def health(self):
        status = self.cli("status")
        windows = self.cli("windows")
        if status.get("transition_error") or any(
            window.get("placement_error") for window in windows
        ):
            raise RuntimeError(
                f"Native placement/transition error: {status}; {windows}"
            )

    def fixture(self):
        return read_json(self.report_path)

    def config(self, gap):
        replacement = self.config_path.with_suffix(".pending")
        duration = 0.12 if self.arguments.scenes else 0
        replacement.write_text(
            f"return {{gap={gap}, motion_duration={duration}, "
            "workspaces={'One','Two'}, bindings={}}\n"
        )
        replacement.replace(self.config_path)

    def tiled(self, report, gap):
        observed = list(frames(report).values())
        screens = [screen["visible_frame"] for screen in report["screens"]]
        return (
            len(observed) == 3
            and all(
                any(contains(screen, frame, gap) for screen in screens)
                for frame in observed
            )
            and not any(
                overlaps(first, second)
                for first, second in itertools.combinations(observed, 2)
            )
        )

    def corner_parked(self, report, before, active_screen, active_titles):
        observed = frames(report)
        other_screens = [
            screen["full_bounds"]
            for screen in report["screens"]
            if screen["visible_frame"] != active_screen
        ]
        evidence = {}
        for title in active_titles:
            original = before[title]
            actual = observed[title]
            candidates = {
                "bottom-right": dict(
                    original,
                    left=active_screen["left"] + active_screen["width"] - 1,
                    top=active_screen["top"] + active_screen["height"] - 1,
                ),
                "bottom-left": dict(
                    original,
                    left=active_screen["left"] + 1 - original["width"],
                    top=active_screen["top"] + active_screen["height"] - 1,
                ),
            }
            chosen = next(
                (
                    corner
                    for corner, candidate in candidates.items()
                    if not any(
                        overlaps(candidate, screen, tolerance=0)
                        for screen in other_screens
                    )
                ),
                None,
            )
            horizontal_contact = max(
                0,
                min(
                    active_screen["left"] + active_screen["width"],
                    actual["left"] + actual["width"],
                )
                - max(active_screen["left"], actual["left"]),
            )
            bottom = active_screen["top"] + active_screen["height"]
            vertical_contact = max(
                0,
                min(bottom, actual["top"] + actual["height"])
                - max(active_screen["top"], actual["top"]),
            )
            evidence[title] = {
                "before": original,
                "actual": actual,
                "chosen_corner": chosen,
                "desired": candidates.get(chosen),
                "corner_contact_points": {
                    "horizontal": horizontal_contact,
                    "vertical": vertical_contact,
                },
                "size_preserved": all(
                    abs(actual[field] - original[field]) <= 2
                    for field in ("width", "height")
                ),
                "one_point_vertical_strip_with_two_point_readback_tolerance": (
                    chosen is not None
                    and abs(actual["left"] - candidates[chosen]["left"]) <= 2
                    and abs(
                        actual["left"]
                        + actual["width"]
                        - candidates[chosen]["left"]
                        - candidates[chosen]["width"]
                    )
                    <= 2
                    and 0 < horizontal_contact <= 3
                    and active_screen["top"] <= actual["top"] <= bottom
                    and actual["top"] + actual["height"] >= bottom
                ),
                "intersects_other_display": any(
                    overlaps(actual, screen, tolerance=0) for screen in other_screens
                ),
            }
        unchanged = all(
            close_frame(observed[title], original, tolerance=2)
            for title, original in before.items()
            if title not in active_titles
        )
        self.result["corner_parking"] = {
            "visible_frame": active_screen,
            "other_full_bounds": other_screens,
            "screen_bounds": report["screens"],
            "windows": evidence,
            "other_display_frames_unchanged": unchanged,
        }
        return unchanged and all(
            item["size_preserved"]
            and item["one_point_vertical_strip_with_two_point_readback_tolerance"]
            and not item["intersects_other_display"]
            for item in evidence.values()
        )

    def exercise(self):
        if process_ids("huen-wm") or process_ids("HuenFixture"):
            raise RuntimeError(
                "Refusing to run while huen-wm or HuenFixture already exists"
            )
        if (
            not self.binary.is_file()
            or not (self.arguments.fixture / "Contents/MacOS/HuenFixture").is_file()
        ):
            raise RuntimeError(
                "Build the fixture and select an existing installed manager app first"
            )
        self.launch(self.arguments.app, "doctor", "doctor")
        permissions = self.wait(
            "LaunchServices permissions",
            lambda: read_json(self.output / "doctor.stdout.log"),
            lambda report: "accessibility" in report,
            healthy=False,
        )
        if not permissions["accessibility"] or (
            self.arguments.scenes and not permissions.get("screen_capture")
        ):
            raise RuntimeError(f"Required permissions unavailable: {permissions}")
        if process_ids("huen-wm") or process_ids("HuenFixture"):
            raise RuntimeError(
                "A manager or fixture appeared during preflight; refusing launch"
            )
        if process_ids("AeroSpace"):
            if not self.aerospace:
                raise RuntimeError("AeroSpace runs but its CLI is unavailable")
            paused = self.run_command(
                [self.aerospace, "enable", "off", "--fail-if-noop"], required=False
            )
            self.aerospace_changed = paused.returncode == 0
            if not self.aerospace_changed:
                if paused.returncode != 2 or paused.stdout or paused.stderr:
                    raise RuntimeError(
                        f"Cannot pause AeroSpace: {paused.returncode}; "
                        f"{paused.stderr or paused.stdout}"
                    )
                ready = self.run_command(
                    [self.aerospace, "echo", "--", "huen-smoke-ready"]
                )
                if ready.stdout.strip() != "huen-smoke-ready":
                    raise RuntimeError("Cannot confirm AeroSpace CLI connection")
        self.launch(
            self.arguments.fixture,
            "fixture",
            "--report",
            self.report_path,
            "--spread",
            foreground=True,
        )
        original = self.wait(
            "fixture ready",
            self.fixture,
            lambda report: (
                report.get("ready")
                and len(report["windows"]) == 3
                and key_title(report) == "Huen Fixture Alpha"
            ),
            healthy=False,
        )
        self.fixture_pid = original["process_id"]
        original_frames = frames(original)
        original_screens = {
            title: next(
                screen["visible_frame"]
                for screen in original["screens"]
                if contains(screen["visible_frame"], frame)
            )
            for title, frame in original_frames.items()
        }
        self.config(12)
        self.launch(
            self.arguments.app,
            "manager",
            "start",
            "--app",
            "dev.huen-wm.fixture",
            "--config",
            self.config_path,
        )
        self.manager_started = True
        self.wait(
            "filtered manager ready",
            lambda: self.cli("status", required=False),
            lambda status: (
                status.get("running") and status.get("filter") == "dev.huen-wm.fixture"
            ),
            healthy=False,
        )
        self.wait(
            "fixture-only management",
            lambda: self.cli("windows"),
            lambda windows: (
                len(windows) == 3
                and all(window["pid"] == self.fixture_pid for window in windows)
            ),
        )
        tiled = self.wait(
            "native tiling",
            self.fixture,
            lambda report: (
                self.tiled(report, 12)
                and all(
                    contains(original_screens[title], frame, 12)
                    for title, frame in frames(report).items()
                )
                and all(
                    not close_frame(frame, original_frames[title])
                    for title, frame in frames(report).items()
                )
            ),
        )
        self.result["snapshots"]["monitors"] = self.cli("monitors")
        self.result["snapshots"]["workspaces"] = self.cli("workspaces")
        focused = key_title(tiled)
        if not focused:
            raise RuntimeError("Fixture has no native key window")
        active_frame = frames(tiled)[focused]
        active_screen = next(
            screen["visible_frame"]
            for screen in tiled["screens"]
            if contains(screen["visible_frame"], active_frame)
        )
        peers = [
            title
            for title, frame in frames(tiled).items()
            if title != focused and contains(active_screen, frame)
        ]
        if not peers:
            raise RuntimeError("Need two fixture windows on the focused display")
        target_frame = frames(tiled)[peers[0]]
        horizontal_delta = target_frame["left"] - active_frame["left"]
        vertical_delta = target_frame["top"] - active_frame["top"]
        direction = (
            ("right" if horizontal_delta > 0 else "left")
            if abs(horizontal_delta) >= abs(vertical_delta)
            else ("down" if vertical_delta > 0 else "up")
        )
        self.cli("focus", direction)
        focused_report = self.wait(
            "native focus changes",
            self.fixture,
            lambda report: key_title(report) in peers,
        )
        focused = key_title(focused_report)
        before_move = frames(focused_report)[focused]
        expected_move = dict(before_move, top=before_move["top"] + 40)
        self.cli("move", "down")
        self.wait(
            "native move is 40 points",
            self.fixture,
            lambda report: close_frame(frames(report)[focused], expected_move),
        )
        self.cli("toggle-floating")
        self.wait(
            "return to tiled", self.fixture, lambda report: self.tiled(report, 12)
        )
        self.cli("layout", "master")
        self.cli("resize", "0.1")
        layout_report = self.wait(
            "layout and resize change native frames",
            self.fixture,
            lambda report: (
                self.tiled(report, 12)
                and any(
                    not close_frame(frame, frames(tiled)[title])
                    for title, frame in frames(report).items()
                )
            ),
        )
        before_workspace = frames(layout_report)
        active_titles = [
            title
            for title, frame in before_workspace.items()
            if contains(active_screen, frame)
        ]
        other_titles = set(before_workspace) - set(active_titles)
        self.result["multi_display_covered"] = bool(other_titles)
        expected_presentation = "captured" if self.arguments.scenes else "instant"
        before_workspace_generation = self.cli("status")["snapshot_generation"]
        self.cli("workspace", "2")
        self.wait(
            "workspace preserves size at one-point vertical strip on active display only",
            self.fixture,
            lambda report: self.corner_parked(
                report, before_workspace, active_screen, active_titles
            ),
        )
        self.wait(
            "workspace transition settles",
            lambda: self.cli("status"),
            lambda status: (
                not status.get("transition_pending")
                and status.get("snapshot_presentation") == expected_presentation
                and status["snapshot_generation"] > before_workspace_generation
            ),
        )
        before_return_generation = self.cli("status")["snapshot_generation"]
        self.cli("workspace", "1")
        self.wait(
            "workspace returns native frames",
            self.fixture,
            lambda report: all(
                close_frame(frame, before_workspace[title], tolerance=2)
                for title, frame in frames(report).items()
            ),
        )
        self.wait(
            "return transition settles",
            lambda: self.cli("status"),
            lambda status: (
                not status.get("transition_pending")
                and status.get("snapshot_presentation") == expected_presentation
                and status["snapshot_generation"] > before_return_generation
            ),
        )
        before_valid_reload = self.cli("status")["config_reload"]["request_id"]
        self.config(32)
        self.wait(
            "valid automatic reload completes",
            lambda: self.cli("status")["config_reload"],
            lambda reload: (
                reload["request_id"] > before_valid_reload
                and reload["state"] == "ready"
            ),
        )
        reloaded = self.wait(
            "valid reload changes native gap",
            self.fixture,
            lambda report: (
                self.tiled(report, 32)
                and any(
                    not close_frame(frame, before_workspace[title])
                    for title, frame in frames(report).items()
                )
            ),
        )
        before_invalid_reload = self.cli("status")["config_reload"]["request_id"]
        self.config_path.write_text("return {gap='invalid'}\n")
        self.wait(
            "invalid automatic reload fails",
            lambda: self.cli("status")["config_reload"],
            lambda reload: (
                reload["request_id"] > before_invalid_reload
                and reload["state"] == "failed"
                and bool(reload["err_message"])
            ),
        )
        before_invalid_move = self.wait(
            "invalid reload preserves native frames",
            self.fixture,
            lambda report: all(
                close_frame(frame, frames(reloaded)[title])
                for title, frame in frames(report).items()
            ),
        )
        focused = key_title(before_invalid_move)
        if not focused:
            raise RuntimeError("Fixture lost native focus after workspace return")
        expected_invalid_move = dict(
            frames(before_invalid_move)[focused],
            top=frames(before_invalid_move)[focused]["top"] + 40,
        )
        self.cli("move", "down")
        self.wait(
            "commands survive invalid reload",
            self.fixture,
            lambda report: close_frame(frames(report)[focused], expected_invalid_move),
        )
        self.cli("toggle-floating")
        self.wait(
            "invalid reload retains native layout",
            self.fixture,
            lambda report: all(
                close_frame(frame, frames(reloaded)[title])
                for title, frame in frames(report).items()
            ),
        )
        self.cli("restore")
        self.wait(
            "restore original native frames before stop",
            self.fixture,
            lambda report: (
                set(frames(report)) == set(original_frames)
                and all(
                    close_frame(frame, original_frames[title], 5)
                    for title, frame in frames(report).items()
                )
            ),
        )
        self.result["passed"] = True

    def cleanup(self):
        manager_stopped = not self.manager_started
        if self.manager_started:
            try:
                identities = process_ids("huen-wm")
                if not identities:
                    manager_stopped = True
                else:
                    status = self.cli("status")
                    if (
                        not status.get("running")
                        or status.get("filter") != "dev.huen-wm.fixture"
                    ):
                        raise RuntimeError(
                            f"Refusing cleanup of an unowned manager: {status}"
                        )
                    if len(identities) != 1:
                        raise RuntimeError("Cannot identify the owned manager process")
                    command = self.run_command(
                        ["ps", "-ww", "-p", identities[0], "-o", "command="]
                    )
                    if str(self.config_path) not in command.stdout:
                        raise RuntimeError(
                            "Manager does not use this run's config; refusing cleanup"
                        )
                    try:
                        self.cli("restore")
                    except Exception as error:
                        self.result["cleanup_errors"].append(
                            f"Cleanup restore failed: {error}"
                        )
                    self.cli("stop")
                    self.wait(
                        "owned manager stopped",
                        lambda: process_ids("huen-wm"),
                        lambda identities: not identities,
                        healthy=False,
                    )
                    manager_stopped = True
            except Exception as error:
                self.result["cleanup_errors"].append(
                    f"Owned manager did not stop: {error}. No hard kill attempted."
                )
        if self.fixture_pid is None:
            report = self.fixture()
            if report and report.get("ready"):
                self.fixture_pid = report["process_id"]
        if self.fixture_pid is not None:
            try:
                if self.fixture_pid in process_ids("HuenFixture"):
                    os.kill(self.fixture_pid, signal.SIGTERM)
                    self.wait(
                        "owned fixture stopped",
                        lambda: process_ids("HuenFixture"),
                        lambda identities: self.fixture_pid not in identities,
                        healthy=False,
                    )
            except Exception as error:
                self.result["cleanup_errors"].append(f"Fixture cleanup failed: {error}")
        if self.aerospace_changed:
            if manager_stopped:
                try:
                    self.run_command([self.aerospace, "enable", "on"])
                except Exception as error:
                    self.result["cleanup_errors"].append(
                        f"AeroSpace restore failed: {error}"
                    )
            else:
                self.result["cleanup_errors"].append(
                    "AeroSpace left disabled because owned manager may still run"
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app", type=Path, default=Path.home() / "Applications/Huen WM.app"
    )
    parser.add_argument(
        "--fixture",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "zig-out/fixtures/HuenFixture.app",
    )
    parser.add_argument(
        "--output", type=Path, required=True, help="New directory for JSON and logs"
    )
    parser.add_argument(
        "--timeout", type=float, default=12, help="Seconds per bounded observation"
    )
    parser.add_argument(
        "--scenes",
        action="store_true",
        help="Require captured snapshots with 0.12-second scenes; not visual proof",
    )
    arguments = parser.parse_args()
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")
    smoke = NativeSmoke(arguments)
    try:
        smoke.exercise()
    except Exception as error:
        smoke.result["failure"] = str(error)
        smoke.result["traceback"] = traceback.format_exc()
        print(f"FAIL {error}", file=sys.stderr)
    finally:
        smoke.cleanup()
        smoke.result["passed"] = (
            smoke.result["passed"] and not smoke.result["cleanup_errors"]
        )
        (smoke.output / "result.json").write_text(
            json.dumps(smoke.result, indent=2) + "\n"
        )
    print(f"Results: {smoke.output / 'result.json'}")
    return 0 if smoke.result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
