"""The GPU pass-through is a CHOICE, and each overlay has to describe its vendor.

Two tracked overlays rather than one template, because "how the host's GPU
reaches the container" differs by vendor in kind, not in degree: NVIDIA has to
bring the closed driver INTO the container, ROCm brings only kernel nodes because
the HIP userspace travels inside the torch wheel. Collapsing them back into one
file is the mistake these tests exist to catch -- an overlay that asks for both
is an overlay that fails on both.

These are text assertions rather than a YAML parse on purpose: this repo has no
install-time dependency beyond pytest, and what needs pinning is which device and
library lines appear in WHICH file, which reading the file states directly.
"""

import os
import re

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NVIDIA = os.path.join(ROOT, "docker-compose.nvidia.yml")
ROCM = os.path.join(ROOT, "docker-compose.rocm.yml")
BASE = os.path.join(ROOT, "docker-compose.yml")
TEMPLATE = os.path.join(ROOT, "docker-compose.override.yml.example")
DOC = os.path.join(ROOT, "docs", "gpu-runtime.md")

NVIDIA_DEVICES = ("/dev/nvidia0", "/dev/nvidiactl", "/dev/nvidia-uvm",
                  "/dev/nvidia-caps")
# The image is Debian. Its loader does not search /usr/lib64, so a driver mounted
# at its own host path is visible in the container and unreadable by torch.
MULTIARCH = "/usr/lib/x86_64-linux-gnu"
DRIVER_LIBS = ("libcuda.so.1", "libnvidia-ml.so.1")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def active_lines(text):
    """The file without comment lines -- an example in a comment is not config."""
    return [line for line in text.splitlines() if not line.lstrip().startswith("#")]


@pytest.fixture(scope="module")
def overlay_text():
    return {"nvidia": read(NVIDIA), "rocm": read(ROCM)}


def test_both_overlays_exist():
    assert os.path.isfile(NVIDIA), "the NVIDIA overlay is missing"
    assert os.path.isfile(ROCM), "the ROCm overlay is missing"


@pytest.mark.parametrize("node", NVIDIA_DEVICES)
def test_nvidia_overlay_passes_the_device_nodes(node):
    assert node in read(NVIDIA), (
        "%s is not in the NVIDIA overlay: torch finds a driver and no device" % node)


@pytest.mark.parametrize("lib", DRIVER_LIBS)
def test_nvidia_overlay_places_the_driver_in_the_multiarch_dir(lib):
    """The destination is the whole point; the source is whatever the host has."""
    text = read(NVIDIA)
    pattern = re.escape(lib) + r":" + re.escape(MULTIARCH) + r"/" + re.escape(lib)
    assert re.search(pattern, text), (
        "%s must be mounted to %s/%s -- mounted at its own host path it is "
        "visible in the container and torch still reports no GPU"
        % (lib, MULTIARCH, lib))


def test_nvidia_overlay_does_not_ask_for_rocm_devices():
    for line in active_lines(read(NVIDIA)):
        assert "/dev/kfd" not in line and "/dev/dri" not in line, (
            "the NVIDIA overlay asks for a ROCm device; container-create then "
            "fails with 'stat /dev/kfd: no such file or directory'")


def test_rocm_overlay_asks_for_kfd_dri_and_the_groups():
    text = read(ROCM)
    assert "/dev/kfd" in text, "the ROCm kernel driver node is missing"
    assert "/dev/dri" in text, "the render node is missing"
    for group in ("video", "render"):
        assert re.search(r"^\s*-\s*%s\s*$" % group, text, re.MULTILINE), (
            "the %s group is not added; a rootless container without it cannot "
            "open the ROCm device" % group)


def test_rocm_overlay_mounts_nothing_nvidia():
    for line in active_lines(read(ROCM)):
        assert "nvidia" not in line.lower(), (
            "the ROCm overlay mentions an NVIDIA device or driver")


def test_rocm_overlay_mounts_no_driver_libraries():
    """HIP userspace ships inside the torch wheel; a mounted one would shadow it."""
    for line in active_lines(read(ROCM)):
        assert "libcuda" not in line and "libamdhip" not in line, (
            "the ROCm overlay mounts a driver library, which the torch build "
            "already provides")


@pytest.mark.parametrize("vendor", ["nvidia", "rocm"])
def test_overlay_is_additive_only(vendor, overlay_text):
    """An overlay carries vendor plumbing, never exposure or secrets."""
    text = overlay_text[vendor]
    for forbidden in ("ports:", "CHOPSHOP_FLUX_TOKEN", "CHOPSHOP_FLUX_BIND"):
        assert forbidden not in text, (
            "%s overlay sets %s; ports, tokens and binds belong to the base "
            "file or the untracked override, not to a tracked vendor overlay"
            % (vendor, forbidden))
    services = [line for line in active_lines(text) if line.strip()]
    assert services[0].strip() == "services:", (
        "%s overlay must be a compose fragment rooted at services:" % vendor)


@pytest.mark.parametrize("vendor", ["nvidia", "rocm"])
def test_overlay_carries_no_host_fact(vendor, overlay_text):
    """AGENTS.md rule 4: no hostname, private IP, or absolute host path."""
    text = overlay_text[vendor]
    for pattern, why in (
        (r"/home/", "an absolute home path"),
        (r"/Users/", "an absolute home path"),
        (r"[a-z0-9-]+\.(?:local|lan|internal)\b", "a hostname"),
    ):
        assert not re.search(pattern, text), (
            "the %s overlay contains %s; that belongs in the untracked override"
            % (vendor, why))
    for address in re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", text):
        assert address == "127.0.0.1", (
            "the %s overlay contains the address %s" % (vendor, address))


@pytest.mark.parametrize("path", [BASE, TEMPLATE, DOC, os.path.join(ROOT, "README.md")])
def test_every_doc_names_both_overlays(path):
    """A rename in one place and not the others is how the flag gets lost."""
    text = read(path)
    for name in ("docker-compose.nvidia.yml", "docker-compose.rocm.yml"):
        assert name in text, (
            "%s does not name %s, so half the readers are sent to a path that "
            "does not exist" % (os.path.basename(path), name))
