#!/usr/bin/env python3
"""Check native fixture observations against the installed manager's CLI."""

import argparse
import ctypes
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


WORKFLOW_GAP = 12


def inset(bounds, amount):
    return {
        "left": bounds["left"] + amount,
        "top": bounds["top"] + amount,
        "width": bounds["width"] - 2 * amount,
        "height": bounds["height"] - 2 * amount,
    }


def frames(report):
    return {window["title"]: window["frame"] for window in report["windows"]}


def key_title(report):
    return next(
        (window["title"] for window in report["windows"] if window["key"]), None
    )


GRAPHICS = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"


class Skipped(Exception):
    pass


class GraphicsPoint(ctypes.Structure):
    _fields_ = [("left", ctypes.c_double), ("top", ctypes.c_double)]


def graphics():
    library = ctypes.CDLL(GRAPHICS)
    library.CGEventCreate.restype = ctypes.c_void_p
    library.CGEventCreate.argtypes = [ctypes.c_void_p]
    library.CGEventGetLocation.restype = GraphicsPoint
    library.CGEventGetLocation.argtypes = [ctypes.c_void_p]
    library.CGWarpMouseCursorPosition.restype = ctypes.c_int32
    library.CGWarpMouseCursorPosition.argtypes = [GraphicsPoint]
    library.CGGetActiveDisplayList.restype = ctypes.c_int32
    library.CGGetActiveDisplayList.argtypes = [
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    library.CGDisplayIsBuiltin.restype = ctypes.c_bool
    library.CGDisplayIsBuiltin.argtypes = [ctypes.c_uint32]
    return library


def active_displays():
    library = graphics()
    identities = (ctypes.c_uint32 * 32)()
    count = ctypes.c_uint32(0)
    if library.CGGetActiveDisplayList(32, identities, ctypes.byref(count)):
        raise RuntimeError("Cannot list active displays")
    return [
        {
            "id": identities[index],
            "built_in": library.CGDisplayIsBuiltin(identities[index]),
        }
        for index in range(count.value)
    ]


def pointer_location():
    library = graphics()
    foundation = ctypes.CDLL(FOUNDATION)
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    event = library.CGEventCreate(None)
    if not event:
        raise RuntimeError("Cannot read the pointer location")
    location = library.CGEventGetLocation(event)
    foundation.CFRelease(event)
    return {"left": location.left, "top": location.top}


def warp_pointer(point):
    if graphics().CGWarpMouseCursorPosition(GraphicsPoint(point["left"], point["top"])):
        raise RuntimeError(f"Cannot warp the pointer to {point}")


def center(bounds):
    return {
        "left": bounds["left"] + bounds["width"] / 2,
        "top": bounds["top"] + bounds["height"] / 2,
    }


def inside(bounds, point):
    return (
        bounds["left"] <= point["left"] < bounds["left"] + bounds["width"]
        and bounds["top"] <= point["top"] < bounds["top"] + bounds["height"]
    )


def near(first, second, tolerance=2):
    return (
        abs(first["left"] - second["left"]) <= tolerance
        and abs(first["top"] - second["top"]) <= tolerance
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
            "workflow": arguments.workflow,
            "owner": arguments.owner,
            "monitors": arguments.monitors,
        }
        self.fixture_pid = None
        self.manager_started = False
        self.aerospace_changed = False
        self.aerospace = shutil.which("aerospace")
        self.display = None
        self.screen = None
        self.identities = {}
        self.monitors = {}
        self.built_in = None
        self.external = None

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
            observed_side = next(
                (
                    corner
                    for corner, candidate in candidates.items()
                    if abs(actual["left"] - candidate["left"]) <= 2
                    and abs(
                        actual["left"]
                        + actual["width"]
                        - candidate["left"]
                        - candidate["width"]
                    )
                    <= 2
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
                "observed_side": observed_side,
                "desired": candidates.get(observed_side),
                "corner_contact_points": {
                    "horizontal": horizontal_contact,
                    "vertical": vertical_contact,
                },
                "size_preserved": all(
                    abs(actual[field] - original[field]) <= 2
                    for field in ("width", "height")
                ),
                "one_point_vertical_strip_with_two_point_readback_tolerance": (
                    observed_side is not None
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

    def preflight(self):
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

    def launch_fixture(self, *arguments):
        self.launch(
            self.arguments.fixture,
            "fixture",
            "--report",
            self.report_path,
            *arguments,
            foreground=True,
        )

    def start_manager(self):
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

    def exercise(self):
        self.preflight()
        self.launch_fixture("--spread")
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
        self.start_manager()
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

    def workflow_config(self):
        replacement = self.config_path.with_suffix(".pending")
        replacement.write_text(
            f"return {{gap={WORKFLOW_GAP}, motion_duration=0, "
            "workspaces={'One','Two','Three'}, workspace_back_and_forth=true, "
            "bindings={}}\n"
        )
        replacement.replace(self.config_path)

    def check(self, name, passed, evidence):
        self.result["checks"].append(
            {"name": name, "passed": passed, "evidence": evidence}
        )
        if not passed:
            raise RuntimeError(f"Check failed: {name}; evidence: {evidence}")
        print(f"PASS {name}", flush=True)

    def reply(self, name, arguments, predicate):
        response = self.cli(*arguments, required=False)
        self.check(
            name,
            isinstance(response, dict) and predicate(response),
            {"argv": list(arguments), "reply": response},
        )
        return response

    def rejected(self, name, arguments, error_name):
        return self.reply(
            name,
            arguments,
            lambda response: (
                response.get("error") is True
                and response.get("err_message") == error_name
            ),
        )

    def targets(self, name, arguments, title):
        return self.reply(
            name,
            arguments,
            lambda response: (
                response.get("ok") is True
                and response.get("target") == self.identities[title]
            ),
        )

    def observe(self):
        listing = self.cli("workspaces")
        return {
            "report": self.fixture(),
            "windows": self.cli("windows"),
            "active": next(
                (
                    item["index"]
                    for item in listing
                    if item["display"] == self.display and item["active"]
                ),
                None,
            ),
        }

    def parked(self, frame):
        contact = min(
            self.screen["left"] + self.screen["width"],
            frame["left"] + frame["width"],
        ) - max(self.screen["left"], frame["left"])
        return contact <= 3

    def shows(self, observation, workspace, titles, key):
        report = observation["report"]
        if not report or observation["active"] != workspace:
            return False
        observed = frames(report)
        managed = {window["title"]: window for window in observation["windows"]}
        if set(observed) != set(self.identities) or set(managed) != set(
            self.identities
        ):
            return False
        for title in self.identities:
            window = managed[title]
            if title in titles:
                if (
                    window["workspace"] != workspace
                    or window["parked"]
                    or not contains(self.screen, observed[title], WORKFLOW_GAP)
                ):
                    return False
            elif not window["parked"] or not self.parked(observed[title]):
                return False
        return key is None or key_title(report) == key

    def view(self, name, workspace, titles, key=None):
        return self.wait(
            name,
            self.observe,
            lambda observation: self.shows(observation, workspace, titles, key),
        )

    def switch(self, name, selector, workspace, titles, key=None):
        self.cli("workspace", selector)
        return self.view(name, workspace, titles, key)

    def focused(self, observation, candidates):
        title = key_title(observation["report"])
        if title not in candidates:
            raise RuntimeError(f"Expected native focus within {candidates}: {title}")
        return title

    def framed(self, name, expected, key=None):
        return self.wait(
            name,
            self.fixture,
            lambda report: (
                all(
                    close_frame(frames(report)[title], frame)
                    for title, frame in expected.items()
                )
                and (key is None or key_title(report) == key)
            ),
        )

    def cycle_step(self, name, step, order, current):
        expected = order[(order.index(current) + step) % len(order)]
        direction = "next" if step > 0 else "previous"
        self.targets(f"{name} targets {expected}", ("cycle", direction), expected)
        self.view(f"{name} focuses {expected}", 1, set(order), expected)
        return expected

    def exercise_workflow(self):
        self.preflight()
        self.launch_fixture("--windows", "3")
        original = self.wait(
            "fixture ready",
            self.fixture,
            lambda report: (
                report.get("ready")
                and len(report["windows"]) == 3
                and key_title(report) is not None
            ),
            healthy=False,
        )
        self.fixture_pid = original["process_id"]
        original_frames = frames(original)
        self.workflow_config()
        self.start_manager()
        managed = self.wait(
            "fixture-only management on one display",
            lambda: self.cli("windows"),
            lambda windows: (
                len(windows) == 3
                and all(window["pid"] == self.fixture_pid for window in windows)
                and len({window["display"] for window in windows}) == 1
            ),
        )
        self.display = managed[0]["display"]
        self.identities = {window["title"]: window["id"] for window in managed}
        everyone = set(self.identities)
        tiled = self.wait(
            "native tiling on one display",
            self.fixture,
            lambda report: (
                self.tiled(report, WORKFLOW_GAP)
                and any(
                    all(
                        contains(screen["visible_frame"], frame, WORKFLOW_GAP)
                        for frame in frames(report).values()
                    )
                    for screen in report["screens"]
                )
            ),
        )
        self.screen = next(
            screen["visible_frame"]
            for screen in tiled["screens"]
            if all(
                contains(screen["visible_frame"], frame, WORKFLOW_GAP)
                for frame in frames(tiled).values()
            )
        )
        self.result["snapshots"]["monitors"] = self.cli("monitors")
        self.result["snapshots"]["workspaces"] = self.cli("workspaces")
        self.view("all windows shown on workspace 1", 1, everyone)

        self.rejected(
            "workspace previous before any switch",
            ("workspace", "previous"),
            "NoPreviousWorkspace",
        )
        self.reply(
            "workspace occupied+1 alone replies unchanged",
            ("workspace", "occupied+1"),
            lambda response: (
                response.get("ok") is True and response.get("changed") is False
            ),
        )
        self.view("workspace occupied+1 alone stays on 1", 1, everyone)
        self.switch("workspace -1 wraps from 1 to 3", "-1", 3, set())
        self.switch("workspace +1 wraps from 3 to 1", "+1", 1, everyone)
        self.switch("workspace 2 parks every window", "2", 2, set())
        self.switch("workspace previous returns to 1", "previous", 1, everyone)
        self.switch("workspace 2 again", "2", 2, set())
        self.switch(
            "workspace 2 on 2 returns to previous with back-and-forth",
            "2",
            1,
            everyone,
        )
        self.switch("workspace name:Two resolves to 2", "name:Two", 2, set())
        self.rejected(
            "workspace name:Missing is unknown",
            ("workspace", "name:Missing"),
            "UnknownWorkspaceName",
        )
        self.switch("workspace name:One resolves to 1", "name:One", 1, everyone)
        self.switch("workspace empty selects first empty 2", "empty", 2, set())
        self.switch("workspace next-empty from 2 selects 3", "next-empty", 3, set())
        returned = self.switch("workspace 1 before focus history", "1", 1, everyone)

        first = self.focused(returned, everyone)
        second = self.titles_by_identity()[self.cli("cycle", "next")["target"]]
        self.view("cycle next prepares focus history", 1, everyone, second)
        self.cli("focus", "last")
        self.view("focus last returns to previous window", 1, everyone, first)
        self.cli("focus", "last")
        self.view("focus last toggles back", 1, everyone, second)
        self.targets(
            "move-to-workspace 3 targets the focused window",
            ("move-to-workspace", "3"),
            second,
        )
        self.view(
            "move-to-workspace 3 shows and focuses moved window on 3",
            3,
            {second},
            second,
        )
        self.cli("focus", "last")
        self.view("focus last switches to workspace 1", 1, everyone - {second}, first)
        self.cli("focus", "last")
        self.view("focus last switches back to workspace 3", 3, {second}, second)
        self.targets("cycle next with one window targets it", ("cycle", "next"), second)
        self.view("cycle next with one window keeps focus", 3, {second}, second)
        self.switch(
            "workspace occupied+1 wraps from 3 to 1",
            "occupied+1",
            1,
            everyone - {second},
        )
        self.switch("workspace occupied+1 skips empty 2", "occupied+1", 3, {second})

        remaining = self.switch(
            "workspace 1 before filling 2", "1", 1, everyone - {second}
        )
        third = self.focused(remaining, everyone - {second})
        self.cli("move-to-workspace", "2")
        self.view("move-to-workspace 2 fills every workspace", 2, {third}, third)
        self.rejected(
            "workspace empty with every workspace occupied",
            ("workspace", "empty"),
            "NoEmptyWorkspace",
        )
        self.rejected(
            "workspace next-empty with every workspace occupied",
            ("workspace", "next-empty"),
            "NoEmptyWorkspace",
        )
        self.cli("move-to-workspace", "1")
        self.view("move-to-workspace 1 regroups", 1, everyone - {second}, third)
        self.switch("workspace 3 before regrouping", "3", 3, {second}, second)
        self.cli("move-to-workspace", "1")
        self.view("all windows regrouped on 1", 1, everyone, second)

        settled = self.wait(
            "regrouped dwindle tiles settle",
            self.observe,
            lambda observation: (
                self.shows(observation, 1, everyone, None)
                and self.tiled(observation["report"], WORKFLOW_GAP)
            ),
        )
        tile_frames = frames(settled["report"])
        order = sorted(
            everyone,
            key=lambda title: (
                round(tile_frames[title]["top"]),
                round(tile_frames[title]["left"]),
                self.identities[title],
            ),
        )
        self.result["workflow_reading_order"] = order
        current = self.focused(settled, everyone)
        for count in range(1, 4):
            current = self.cycle_step(f"cycle next {count}", 1, order, current)
        for count in range(1, 4):
            current = self.cycle_step(f"cycle previous {count}", -1, order, current)

        source = current
        neighbor = order[(order.index(source) + 1) % len(order)]
        swapped = dict(
            tile_frames,
            **{source: tile_frames[neighbor], neighbor: tile_frames[source]},
        )
        self.cli("swap", "next")
        self.framed(
            "swap next exchanges reading-order neighbor frames", swapped, source
        )
        self.cli("swap", "previous")
        self.framed("swap previous restores tile frames", tile_frames, source)

        self.cli("toggle-floating")
        self.wait(
            "focused window floats",
            lambda: self.cli("windows"),
            lambda windows: any(
                window["title"] == source and window["floating"] for window in windows
            ),
        )
        self.rejected(
            "swap next on floating window", ("swap", "next"), "WindowNotTiled"
        )
        area = inset(self.screen, WORKFLOW_GAP)
        floating = frames(self.fixture())[source]
        corner = dict(
            floating,
            left=area["left"] + area["width"] - floating["width"],
            top=area["top"] + area["height"] - floating["height"],
        )
        self.cli("move-by", "10000", "10000")
        self.framed(
            "move-by stays inside the bottom-right of the visible area",
            {source: corner},
        )
        self.cli("move-by", "-10000", "-10000")
        self.framed(
            "move-by stays inside the top-left of the visible area",
            {source: dict(floating, left=area["left"], top=area["top"])},
        )
        centered = dict(
            floating,
            left=area["left"] + (area["width"] - floating["width"]) / 2,
            top=area["top"] + (area["height"] - floating["height"]) / 2,
        )
        self.cli("center")
        self.framed("center centers in the visible area", {source: centered})
        shrunk = dict(
            centered,
            width=centered["width"] - 100,
            height=centered["height"] - 60,
        )
        self.cli("resize-by", "-100", "-60")
        self.framed("resize-by shrinks and keeps top-left", {source: shrunk})
        self.cli("resize-by", "10000", "10000")
        self.framed(
            "resize-by grows to the visible edge and keeps top-left",
            {
                source: dict(
                    shrunk,
                    width=area["left"] + area["width"] - shrunk["left"],
                    height=area["top"] + area["height"] - shrunk["top"],
                )
            },
        )
        tiled_peer = self.titles_by_identity()[
            self.cli("cycle", "next", "tiled")["target"]
        ]
        self.framed("cycle next tiled leaves the floating window", {}, tiled_peer)
        self.rejected("center on tiled window", ("center",), "WindowNotFloating")
        self.rejected(
            "move-by on tiled window", ("move-by", "10", "10"), "WindowNotFloating"
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

    def write_config(self, content):
        replacement = self.config_path.with_suffix(".pending")
        replacement.write_text(content)
        replacement.replace(self.config_path)

    def monitor_config(self, owners, follows):
        routing = (
            ""
            if owners is None
            else "workspace_monitors={"
            + ",".join(f"'{owner}'" for owner in owners)
            + "}, "
        )
        follow = "true" if follows else "false"
        self.write_config(
            f"return {{gap={WORKFLOW_GAP}, motion_duration=0, "
            f"workspaces={{'One','Two','Three'}}, {routing}"
            f"mouse_follows_monitor={follow}, bindings={{}}}}\n"
        )

    def reload_monitors(self, name, owners, follows):
        before = self.cli("status")["config_reload"]["request_id"]
        self.monitor_config(owners, follows)
        self.wait(
            name,
            lambda: self.cli("status")["config_reload"],
            lambda reload: reload["request_id"] > before and reload["state"] == "ready",
        )

    def start_multi_display(self, owners, follows):
        found = active_displays()
        self.result["active_displays"] = found
        if (
            len(found) < 2
            or all(item["built_in"] for item in found)
            or not any(item["built_in"] for item in found)
        ):
            raise Skipped(
                "Needs at least two displays, one built-in and one external; "
                f"found {found}"
            )
        self.preflight()
        self.launch_fixture("--spread")
        original = self.wait(
            "fixture ready",
            self.fixture,
            lambda report: (
                report.get("ready")
                and len(report["windows"]) == 3
                and key_title(report) is not None
            ),
            healthy=False,
        )
        self.fixture_pid = original["process_id"]
        self.monitor_config(owners, follows)
        self.start_manager()
        managed = self.wait(
            "fixture-only management",
            lambda: self.cli("windows"),
            lambda windows: (
                len(windows) == 3
                and all(window["pid"] == self.fixture_pid for window in windows)
            ),
        )
        self.identities = {window["title"]: window["id"] for window in managed}
        listing = self.cli("monitors")
        self.result["snapshots"]["monitors"] = listing
        self.monitors = {monitor["id"]: monitor for monitor in listing}
        built_in = [
            identity for identity, item in self.monitors.items() if item["built_in"]
        ]
        external = [
            identity for identity, item in self.monitors.items() if not item["built_in"]
        ]
        if not built_in or not external:
            raise RuntimeError(
                f"Manager monitors lack a built-in or external display: {listing}"
            )
        self.built_in = min(built_in)
        self.external = min(external)
        return frames(original)

    def restored(self, original_frames):
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

    def observe_routing(self):
        return {
            "status": self.cli("status"),
            "windows": self.cli("windows"),
            "workspaces": self.cli("workspaces"),
            "report": self.fixture(),
            "pointer": pointer_location(),
        }

    def routes(self, observation, owner, active, shown, memberships):
        report = observation["report"]
        if not report or observation["status"].get("workspace_owner") != owner:
            return False
        listing = observation["workspaces"]
        if not listing or any(item["display"] != owner for item in listing):
            return False
        if [item["index"] for item in listing if item["active"]] != [active]:
            return False
        managed = {window["title"]: window for window in observation["windows"]}
        observed = frames(report)
        if set(managed) != set(self.identities) or set(observed) != set(
            self.identities
        ):
            return False
        area = self.monitors[owner]["frame"]
        for title, window in managed.items():
            if window["display"] != owner:
                return False
            if window["workspace"] != memberships.get(title, active):
                return False
            if title in shown:
                if window["parked"] or not contains(
                    area, observed[title], WORKFLOW_GAP
                ):
                    return False
            elif not window["parked"] or overlaps(area, observed[title]):
                return False
        return not any(
            overlaps(observed[first], observed[second])
            for first, second in itertools.combinations(sorted(shown), 2)
        )

    def routed(self, name, owner, active, shown, memberships=None):
        return self.wait(
            name,
            self.observe_routing,
            lambda observation: self.routes(
                observation, owner, active, shown, memberships or {}
            ),
        )

    def place_pointer(self, display):
        target = center(self.monitors[display]["full_bounds"])
        warp_pointer(target)
        self.wait(
            f"pointer placed on display {display}",
            pointer_location,
            lambda point: near(point, target),
        )
        return target

    def selected(self, name, display, pointer=None):
        return self.wait(
            name,
            lambda: {"status": self.cli("status"), "pointer": pointer_location()},
            lambda observation: (
                observation["status"].get("selected_monitor") == display
                and (pointer is None or self.pointer_rests(observation["pointer"], pointer))
            ),
        )

    def pointer_rests(self, observed, expected):
        # A warp lands on a display center; manual pointer drift stays on the expected display.
        if near(observed, expected):
            return True
        home = self.display_at(expected)
        return (
            home is not None
            and self.display_at(observed) == home
            and not any(
                near(observed, center(monitor["full_bounds"]))
                for monitor in self.monitors.values()
            )
        )

    def display_at(self, point):
        for identity, monitor in self.monitors.items():
            bounds = monitor["full_bounds"]
            if (
                bounds["left"] <= point["left"] < bounds["left"] + bounds["width"]
                and bounds["top"] <= point["top"] < bounds["top"] + bounds["height"]
            ):
                return identity
        return None

    def exercise_owner(self):
        original_frames = self.start_multi_display(("external", "built-in"), False)
        owner = self.external
        other = self.built_in
        everyone = set(self.identities)
        self.result["owner_displays"] = {"external": owner, "built_in": other}
        resting = self.place_pointer(other)
        self.routed(
            "owner mode migrates every window to the external owner", owner, 1, everyone
        )
        self.cli("workspace", "2")
        self.routed(
            "workspace 2 parks every window on the owner",
            owner,
            2,
            set(),
            {title: 1 for title in everyone},
        )
        self.cli("workspace", "1")
        self.routed("workspace 1 shows every window on the owner", owner, 1, everyone)
        self.selected(
            "workspace 1 selects the owner without a pointer warp", owner, resting
        )
        sent = key_title(
            self.wait(
                "workspace 1 focuses a fixture window",
                self.fixture,
                lambda report: key_title(report) in everyone,
            )
        )
        before = self.cli("status")
        self.reply(
            "send-to-workspace 2 is accepted",
            ("send-to-workspace", "2"),
            lambda response: response.get("ok") is True,
        )
        after = self.routed(
            "send-to-workspace 2 parks only the sent window and keeps workspace 1",
            owner,
            1,
            everyone - {sent},
            {sent: 2},
        )
        self.check(
            "send-to-workspace keeps the owner and selected monitor",
            after["status"]["workspace_owner"] == owner
            and after["status"]["selected_monitor"] == before["selected_monitor"],
            {"before": before, "after": after["status"]},
        )
        self.cli("workspace", "2")
        self.routed(
            "workspace 2 shows the sent window",
            owner,
            2,
            {sent},
            {title: 1 for title in everyone - {sent}},
        )
        self.wait(
            "workspace 2 focuses the sent window",
            self.fixture,
            lambda report: key_title(report) == sent,
        )
        self.reply(
            "send-to-workspace 1 is accepted",
            ("send-to-workspace", "1"),
            lambda response: response.get("ok") is True,
        )
        self.routed(
            "send-to-workspace 1 returns the window and leaves workspace 2 empty",
            owner,
            2,
            set(),
            {title: 1 for title in everyone},
        )
        self.cli("workspace", "1")
        self.routed("workspace 1 shows every window again", owner, 1, everyone)

        resting = self.place_pointer(owner)
        self.reload_monitors(
            "reload makes the built-in display the owner",
            ("built-in", "external"),
            False,
        )
        self.routed(
            "owner change migrates every window to built-in", other, 1, everyone
        )
        self.selected("background routing keeps the selected monitor", owner, resting)
        self.cli("workspace", "1")
        self.selected(
            "workspace 1 selects the new owner without a pointer warp", other, resting
        )

        resting = self.place_pointer(other)
        self.reload_monitors(
            "reload restores the external owner with mouse follow",
            ("external", "built-in"),
            True,
        )
        self.routed(
            "owner change migrates every window back to external", owner, 1, everyone
        )
        self.selected("background routing does not warp the pointer", other, resting)
        self.cli("workspace", "1")
        self.selected(
            "workspace 1 selects the owner and warps the pointer",
            owner,
            center(self.monitors[owner]["full_bounds"]),
        )
        self.restored(original_frames)
        self.result["passed"] = True

    def expected_monitor(self, selector, current):
        screens = list(self.monitors.values())
        if selector in ("left", "right", "up", "down"):
            source = center(self.monitors[current]["full_bounds"])
            best = None
            for screen in screens:
                if screen["id"] == current:
                    continue
                target = center(screen["full_bounds"])
                horizontal = target["left"] - source["left"]
                vertical = target["top"] - source["top"]
                primary = {
                    "left": -horizontal,
                    "right": horizontal,
                    "up": -vertical,
                    "down": vertical,
                }[selector]
                if primary <= 0:
                    continue
                perpendicular = abs(
                    vertical if selector in ("left", "right") else horizontal
                )
                candidate = (primary, perpendicular, screen["id"])
                if best is None or candidate < best:
                    best = candidate
            return None if best is None else best[2]
        if selector in ("next", "previous"):
            order = [
                screen["id"]
                for screen in sorted(
                    screens,
                    key=lambda screen: (
                        center(screen["full_bounds"])["left"],
                        center(screen["full_bounds"])["top"],
                        screen["id"],
                    ),
                )
            ]
            step = 1 if selector == "next" else -1
            return order[(order.index(current) + step) % len(order)]
        if selector in ("built-in", "external"):
            return min(
                screen["id"]
                for screen in screens
                if screen["built_in"] == (selector == "built-in")
            )
        name = selector.removeprefix("name:")
        return min(screen["id"] for screen in screens if screen["name"] == name)

    def titles_on(self, display):
        return {
            window["title"]
            for window in self.cli("windows")
            if window["display"] == display and not window["parked"]
        }

    def focus_monitor(self, label, selector, follows):
        current = self.cli("status")["selected_monitor"]
        resting = self.place_pointer(current)
        before_key = key_title(self.fixture())
        expected = self.expected_monitor(selector, current)
        name = f"{label}: focus-monitor {selector}"
        if expected is None:
            self.rejected(name, ("focus-monitor", selector), "NoMonitorInDirection")
            self.selected(f"{name} keeps selection and pointer", current, resting)
            return current
        self.reply(
            name,
            ("focus-monitor", selector),
            lambda response: (
                response.get("ok") is True
                and response.get("monitor") == expected
                and response.get("changed") == (expected != current)
            ),
        )
        target = (
            center(self.monitors[expected]["full_bounds"])
            if follows and expected != current
            else resting
        )
        self.selected(
            f"{name} selects {expected} with pointer {target}", expected, target
        )
        candidates = self.titles_on(expected) or {before_key}
        self.wait(
            f"{name} key window",
            self.fixture,
            lambda report: key_title(report) in candidates,
        )
        return expected

    def monitor_listing(self, name, workspaces):
        listing = self.cli("monitors")
        self.result["snapshots"][name] = listing
        status = self.cli("status")
        self.check(
            name,
            isinstance(listing, list)
            and {item["id"] for item in listing} == set(self.monitors)
            and all(
                isinstance(item.get("uuid"), str)
                and len(item["uuid"]) == 36
                and item.get("workspace") == workspaces[item["id"]]
                and item.get("selected") == (item["id"] == status["selected_monitor"])
                for item in listing
            ),
            {"monitors": listing, "selected_monitor": status["selected_monitor"]},
        )

    def exercise_monitors(self):
        original_frames = self.start_multi_display(None, True)
        everyone = set(self.identities)
        self.wait(
            "independent mode keeps windows on both displays",
            lambda: self.cli("windows"),
            lambda windows: (
                {window["display"] for window in windows}
                == {self.built_in, self.external}
                and not any(window["parked"] for window in windows)
            ),
        )
        self.monitor_listing(
            "monitors reports uuid, workspace, and selection",
            {identity: 1 for identity in self.monitors},
        )
        external_name = self.monitors[self.external]["name"]
        for selector in (
            "built-in",
            f"name:{external_name}",
            "left",
            "right",
            "up",
            "down",
            "next",
            "previous",
            "external",
            "built-in",
            "next",
        ):
            self.focus_monitor("independent", selector, True)
        self.rejected(
            "focus-monitor name:Missing is unknown",
            ("focus-monitor", "name:Huen Missing Monitor"),
            "UnknownMonitorName",
        )

        self.reload_monitors(
            "reload enables the external owner", ("external", "built-in"), True
        )
        self.routed(
            "owner mode migrates every window to external", self.external, 1, everyone
        )
        self.focus_monitor("owner", "external", True)
        self.monitor_listing(
            "owner monitors list only the owner workspace",
            {self.external: 1, self.built_in: None},
        )
        self.focus_monitor("owner", "built-in", True)
        self.focus_monitor("owner", f"name:{external_name}", True)
        self.focus_monitor("owner", "next", True)
        self.cli("workspace", "2")
        self.routed(
            "owner workspace 2 from built-in activates on external",
            self.external,
            2,
            set(),
            {title: 1 for title in everyone},
        )
        self.selected("owner workspace 2 selects external", self.external)
        self.cli("workspace", "1")
        self.routed("owner workspace 1 shows every window", self.external, 1, everyone)

        self.reload_monitors(
            "reload disables mouse follow", ("external", "built-in"), False
        )
        for selector in ("built-in", "external", "previous", "next"):
            self.focus_monitor("owner without mouse follow", selector, False)
        self.restored(original_frames)
        self.result["passed"] = True

    def titles_by_identity(self):
        return {identity: title for title, identity in self.identities.items()}

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
    parser.add_argument(
        "--workflow",
        action="store_true",
        help="Check keyboard workflow commands on one display instead",
    )
    parser.add_argument(
        "--owner",
        action="store_true",
        help="Check workspace_monitors owner routing on two displays instead",
    )
    parser.add_argument(
        "--monitors",
        action="store_true",
        help="Check focus-monitor selectors on two displays instead",
    )
    arguments = parser.parse_args()
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")
    if sum((arguments.workflow, arguments.owner, arguments.monitors)) > 1:
        parser.error("--workflow, --owner, and --monitors are exclusive")
    if arguments.scenes and (
        arguments.workflow or arguments.owner or arguments.monitors
    ):
        parser.error(
            "--workflow, --owner, and --monitors use instant switches and exclude --scenes"
        )
    smoke = NativeSmoke(arguments)
    try:
        if arguments.workflow:
            smoke.exercise_workflow()
        elif arguments.owner:
            smoke.exercise_owner()
        elif arguments.monitors:
            smoke.exercise_monitors()
        else:
            smoke.exercise()
    except Skipped as reason:
        smoke.result["skipped"] = str(reason)
        print(f"SKIP {reason}", flush=True)
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
    if smoke.result.get("skipped") and not smoke.result["cleanup_errors"]:
        return 0
    return 0 if smoke.result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
