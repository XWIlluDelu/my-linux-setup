#!/usr/bin/env python3

import gzip
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple

URL_TIMEOUT = 60
FETCH_RETRIES = 3
LATEST_DOWNLOADS_URL = "https://developer.nvidia.com/cuda-downloads"
ARCHIVE_INDEX_URL = "https://developer.nvidia.com/cuda-toolkit-archive"
INSTALL_GUIDE_URL = "https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"
RELEASE_NOTES_URL = "https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html"


def fetch_bytes(url: str) -> bytes:
    last_error: Optional[Exception] = None
    curl_path = shutil.which("curl")

    for _ in range(FETCH_RETRIES):
        if curl_path:
            try:
                result = subprocess.run(
                    [
                        curl_path,
                        "-fsSL",
                        "--connect-timeout",
                        "10",
                        "--max-time",
                        str(URL_TIMEOUT),
                        url,
                    ],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                return result.stdout
            except subprocess.CalledProcessError as exc:
                last_error = exc
        try:
            with urllib.request.urlopen(url, timeout=URL_TIMEOUT) as response:
                return response.read()
        except Exception as exc:  # pragma: no cover - network fallback
            last_error = exc

    raise RuntimeError(f"Failed to fetch {url}: {last_error}")


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", "replace")


def url_exists(url: str) -> bool:
    request = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=URL_TIMEOUT):
            return True
    except Exception:
        try:
            with urllib.request.urlopen(url, timeout=URL_TIMEOUT):
                return True
        except Exception:
            return False


def version_tuple(version: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def extract_numeric_driver(version: str) -> Optional[str]:
    match = re.search(r"(\d+\.\d+\.\d+)", version)
    if not match:
        return None
    return match.group(1)


def read_os_release() -> Dict[str, str]:
    data: Dict[str, str] = {}
    path = Path("/etc/os-release")
    if not path.exists():
        return data

    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def detect_current_repo_id(os_release: Dict[str, str]) -> Optional[str]:
    distro_id = os_release.get("ID", "")
    version_id = os_release.get("VERSION_ID", "")
    if distro_id == "ubuntu" and version_id:
        return f"ubuntu{version_id.replace('.', '')}"
    if distro_id == "debian" and version_id:
        major = version_id.split(".", 1)[0]
        return f"debian{major}"
    return None


def parse_supported_repo_ids(install_guide_html: str) -> Dict[str, List[str]]:
    supported: Dict[str, List[str]] = {"ubuntu": [], "debian": []}
    for distro, repo_id in re.findall(r"<(?:tr|td)[^>]*>\s*<td><p>(Ubuntu|Debian)\s+[^<]+</p></td>\s*<td><p>([a-z]+\d+)</p>", install_guide_html):
        key = distro.lower()
        if repo_id not in supported[key]:
            supported[key].append(repo_id)
    for key in supported:
        supported[key].sort(key=lambda value: int(re.search(r"(\d+)$", value).group(1)))
    return supported


def pick_fallback_repo_id(current_repo_id: Optional[str], candidates: List[str]) -> Optional[str]:
    if not candidates:
        return None
    if not current_repo_id:
        return candidates[-1]
    if current_repo_id in candidates:
        return current_repo_id

    current_num_match = re.search(r"(\d+)$", current_repo_id)
    if not current_num_match:
        return candidates[-1]
    current_num = int(current_num_match.group(1))

    eligible = []
    for candidate in candidates:
        match = re.search(r"(\d+)$", candidate)
        if not match:
            continue
        value = int(match.group(1))
        if value <= current_num:
            eligible.append((value, candidate))
    if eligible:
        eligible.sort()
        return eligible[-1][1]
    return candidates[-1]


def parse_repo_packages(repo_id: str) -> Dict[str, Dict[str, Optional[str]]]:
    url = f"https://developer.download.nvidia.com/compute/cuda/repos/{repo_id}/x86_64/Packages.gz"
    text = gzip.decompress(fetch_bytes(url)).decode("utf-8", "replace")
    packages: Dict[str, Dict[str, Optional[str]]] = {}

    blocks = text.split("\n\n")
    for block in blocks:
        package_match = re.search(r"^Package: cuda-toolkit-(\d+)-(\d+)$", block, re.M)
        if not package_match:
            continue
        family = f"{package_match.group(1)}.{package_match.group(2)}"
        version_match = re.search(r"^Version: ([^\n]+)$", block, re.M)
        if not version_match:
            continue
        package_name = f"cuda-toolkit-{package_match.group(1)}-{package_match.group(2)}"
        package_version = version_match.group(1).strip()
        package_version_release = package_version.split("-", 1)[0]
        entry = packages.get(family)
        if entry and version_tuple(entry["package_version"]) >= version_tuple(package_version):
            continue
        packages[family] = {
            "package_name": package_name,
            "package_version": package_version,
            "package_release": package_version_release,
            "runtime_dependency_branch": None,
            "runtime_dependency_min_version": None,
        }

    for block in blocks:
        runtime_match = re.search(r"^Package: cuda-runtime-(\d+)-(\d+)$", block, re.M)
        if not runtime_match:
            continue
        family = f"{runtime_match.group(1)}.{runtime_match.group(2)}"
        entry = packages.get(family)
        if not entry:
            continue
        version_match = re.search(r"^Version: ([^\n]+)$", block, re.M)
        depends_match = re.search(r"^Depends: ([^\n]+)$", block, re.M)
        if not version_match or not depends_match:
            continue
        branch_match = re.search(r"libnvidia-compute-(\d+) \(>= ([^)]+)\)", depends_match.group(1))
        if not branch_match:
            continue
        runtime_version = version_match.group(1).strip()
        current_runtime_version = entry.get("runtime_dependency_min_version_source")
        if current_runtime_version and version_tuple(current_runtime_version) >= version_tuple(runtime_version):
            continue
        entry["runtime_dependency_branch"] = branch_match.group(1)
        entry["runtime_dependency_min_version"] = branch_match.group(2)
        entry["runtime_dependency_min_version_source"] = runtime_version

    for entry in packages.values():
        entry.pop("runtime_dependency_min_version_source", None)
    return packages


def parse_release_notes(html_text: str) -> Dict[str, Dict[str, str]]:
    results: Dict[str, Dict[str, str]] = {}
    pattern = re.compile(
        r"CUDA\s+(\d+\.\d+)\s+(Update\s+(\d+)|GA)</p></td>\s*<td><p>&gt;=([0-9.]+)</p>",
        re.I,
    )
    for family, kind, update_num, min_driver in pattern.findall(html_text):
        patch = update_num if update_num else "0"
        release = f"{family}.{patch}"
        label = f"CUDA {family} {kind}"
        record = results.get(family)
        if record and version_tuple(record["release"]) >= version_tuple(release):
            continue
        results[family] = {
            "family": family,
            "release": release,
            "label": label,
            "min_driver": min_driver,
        }
    return results


def parse_archive_latest(html_text: str) -> Optional[str]:
    match = re.search(r"Latest Release</strong><br><a href=\"/cuda-downloads\">CUDA Toolkit ([0-9.]+)", html_text)
    if not match:
        return None
    return match.group(1)


def parse_download_page_react_props(page_html: str) -> Dict:
    match = re.search(r'data-react-props="([^"]+)"', page_html)
    if not match:
        raise RuntimeError("Could not locate NVIDIA download metadata on the page.")
    encoded = match.group(1)
    decoded = html.unescape(encoded)
    return json.loads(decoded)


def build_download_page_url(release: str, latest_release: Optional[str]) -> str:
    if latest_release and release == latest_release:
        return LATEST_DOWNLOADS_URL
    return f"https://developer.nvidia.com/cuda-{release.replace('.', '-')}-download-archive"


def parse_runfile_info(release: str, latest_release: Optional[str]) -> Dict[str, Optional[str]]:
    page_url = build_download_page_url(release, latest_release)
    page_html = fetch_text(page_url)
    props = parse_download_page_react_props(page_html)
    releases = props.get("pageData", {}).get("releases", {})
    for entry in releases.values():
        if not isinstance(entry, dict):
            continue
        if entry.get("arch") != "x86_64":
            continue
        if entry.get("format") != "runfile":
            continue
        filename = entry.get("filename")
        if not filename or not filename.endswith(".run"):
            continue
        return {
            "filename": filename,
            "url": f"https://developer.download.nvidia.com/compute/cuda/{release}/local_installers/{filename}",
            "md5": entry.get("md5sum"),
            "page_url": page_url,
        }
    return {"filename": None, "url": None, "md5": None, "page_url": page_url}


def run_command(args: List[str]) -> str:
    try:
        result = subprocess.run(args, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except FileNotFoundError:
        return ""
    if result.returncode != 0:
        return result.stdout or ""
    return result.stdout


def apt_candidate_version(package_name: str) -> Optional[str]:
    output = run_command(["apt-cache", "policy", package_name])
    match = re.search(r"Candidate:\s*([^\s]+)", output)
    if not match:
        return None
    value = match.group(1).strip()
    if value == "(none)":
        return None
    return value


def detect_installed_open_branch() -> Optional[str]:
    output = run_command(["dpkg-query", "-W", "-f=${Package}\n", "nvidia-driver-*-open"])
    for line in output.splitlines():
        match = re.match(r"nvidia-driver-(\d+)-open$", line.strip())
        if match:
            return match.group(1)
    return None


def detect_current_driver_version() -> Optional[str]:
    output = run_command(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"])
    for line in output.splitlines():
        value = line.strip()
        if value:
            return value
    return None


def detect_gpu_name() -> Optional[str]:
    output = run_command(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"])
    for line in output.splitlines():
        value = line.strip()
        if value:
            return value
    output = run_command(["bash", "-lc", "lspci -nn | grep -i 'NVIDIA' | head -n 1"])
    if output.strip():
        return output.strip()
    return None


def parse_ubuntu_drivers() -> Tuple[List[Dict[str, object]], Optional[str]]:
    output = run_command(["ubuntu-drivers", "devices"])
    drivers: Dict[str, Dict[str, object]] = {}
    recommended_branch: Optional[str] = None
    for line in output.splitlines():
        match = re.search(r"nvidia-driver-(\d+)-open\b", line)
        if not match:
            continue
        if "server" in line:
            continue
        branch = match.group(1)
        entry = drivers.setdefault(branch, {"branch": branch, "package": f"nvidia-driver-{branch}-open", "recommended": False})
        if "recommended" in line:
            entry["recommended"] = True
            recommended_branch = branch
    rows = list(drivers.values())
    rows.sort(key=lambda item: int(item["branch"]))
    return rows, recommended_branch


def fallback_open_drivers() -> List[Dict[str, object]]:
    output = run_command(["bash", "-lc", "apt-cache search '^nvidia-driver-[0-9]+-open$' | sort -V"])
    rows: List[Dict[str, object]] = []
    for line in output.splitlines():
        match = re.match(r"nvidia-driver-(\d+)-open\s+-", line)
        if not match:
            continue
        branch = match.group(1)
        rows.append({"branch": branch, "package": f"nvidia-driver-{branch}-open", "recommended": False})
    return rows


def detect_open_drivers() -> Dict[str, object]:
    rows, recommended_branch = parse_ubuntu_drivers()
    if not rows:
        rows = fallback_open_drivers()

    installed_branch = detect_installed_open_branch()
    current_driver_version = detect_current_driver_version()
    current_driver_numeric = extract_numeric_driver(current_driver_version or "")

    final_rows = []
    for row in rows:
        branch = row["branch"]
        package = row["package"]
        candidate_version = apt_candidate_version(package)
        if not candidate_version:
            continue
        candidate_numeric = extract_numeric_driver(candidate_version)
        final_rows.append(
            {
                "branch": branch,
                "package": package,
                "candidate_version": candidate_version,
                "candidate_numeric": candidate_numeric,
                "recommended": bool(row.get("recommended", False)),
                "installed": installed_branch == branch,
            }
        )
    final_rows.sort(key=lambda item: int(item["branch"]))
    return {
        "rows": final_rows,
        "recommended_branch": recommended_branch,
        "installed_branch": installed_branch,
        "current_driver_version": current_driver_version,
        "current_driver_numeric": current_driver_numeric,
    }


def build_cuda_versions(repo_packages: Dict[str, Dict[str, Optional[str]]], release_notes: Dict[str, Dict[str, str]], latest_release: Optional[str]) -> List[Dict[str, object]]:
    versions: List[Dict[str, object]] = []
    for family, repo_entry in repo_packages.items():
        notes_entry = release_notes.get(family)
        if not notes_entry:
            continue
        runfile_info = parse_runfile_info(notes_entry["release"], latest_release)
        versions.append(
            {
                "family": family,
                "release": notes_entry["release"],
                "label": notes_entry["label"],
                "min_driver": notes_entry["min_driver"],
                "package_name": repo_entry["package_name"],
                "package_version": repo_entry["package_version"],
                "package_release": repo_entry["package_release"],
                "runtime_dependency_branch": repo_entry["runtime_dependency_branch"],
                "runtime_dependency_min_version": repo_entry["runtime_dependency_min_version"],
                "runfile_url": runfile_info["url"],
                "runfile_filename": runfile_info["filename"],
                "runfile_md5": runfile_info["md5"],
                "runfile_page_url": runfile_info["page_url"],
            }
        )
    versions.sort(key=lambda item: version_tuple(item["release"]))
    return versions


def compute_compatibility(drivers: List[Dict[str, object]], cuda_versions: List[Dict[str, object]]) -> Dict[str, Dict[str, object]]:
    by_driver: Dict[str, Dict[str, object]] = {}
    by_cuda: Dict[str, Dict[str, object]] = {}

    for cuda in cuda_versions:
        family = cuda["family"]
        min_driver = cuda["min_driver"]
        compatible_branches: List[str] = []
        for driver in drivers:
            candidate_numeric = driver.get("candidate_numeric")
            if not candidate_numeric:
                continue
            if version_tuple(candidate_numeric) >= version_tuple(min_driver):
                compatible_branches.append(driver["branch"])
        by_cuda[family] = {
            "family": family,
            "compatible_branches": compatible_branches,
            "recommended_branch": compatible_branches[-1] if compatible_branches else None,
        }

    for driver in drivers:
        branch = driver["branch"]
        candidate_numeric = driver.get("candidate_numeric")
        compatible_families: List[str] = []
        best_cuda: Optional[str] = None
        for cuda in cuda_versions:
            min_driver = cuda["min_driver"]
            if candidate_numeric and version_tuple(candidate_numeric) >= version_tuple(min_driver):
                compatible_families.append(cuda["family"])
                best_cuda = cuda["family"]
        by_driver[branch] = {
            "branch": branch,
            "compatible_families": compatible_families,
            "best_cuda": best_cuda,
        }

    return {"by_driver": by_driver, "by_cuda": by_cuda}


def detect_secure_boot_state() -> Optional[bool]:
    path = Path("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c")
    if not path.exists():
        return None
    data = path.read_bytes()
    if len(data) < 5:
        return None
    return data[4] == 1


def main() -> int:
    os_release = read_os_release()
    distro_id = os_release.get("ID", "unknown")
    current_repo_id = detect_current_repo_id(os_release)

    install_guide_html = fetch_text(INSTALL_GUIDE_URL)
    supported_repo_ids = parse_supported_repo_ids(install_guide_html)
    distro_repo_candidates = supported_repo_ids.get(distro_id, [])
    preferred_repo_id = pick_fallback_repo_id(current_repo_id, distro_repo_candidates)
    current_repo_supported = bool(current_repo_id and current_repo_id in distro_repo_candidates)

    archive_html = fetch_text(ARCHIVE_INDEX_URL)
    latest_release = parse_archive_latest(archive_html)
    release_notes_html = fetch_text(RELEASE_NOTES_URL)
    release_notes = parse_release_notes(release_notes_html)

    repo_packages = parse_repo_packages(preferred_repo_id) if preferred_repo_id else {}
    cuda_versions = build_cuda_versions(repo_packages, release_notes, latest_release)

    driver_info = detect_open_drivers()
    compatibility = compute_compatibility(driver_info["rows"], cuda_versions)

    data = {
        "system": {
            "pretty_name": os_release.get("PRETTY_NAME", distro_id),
            "id": distro_id,
            "version_id": os_release.get("VERSION_ID"),
            "arch": os.uname().machine,
            "current_repo_id": current_repo_id,
            "current_repo_supported": current_repo_supported,
            "supported_repo_ids": distro_repo_candidates,
            "preferred_repo_id": preferred_repo_id,
            "preferred_repo_supported": preferred_repo_id == current_repo_id,
            "secure_boot_enabled": detect_secure_boot_state(),
        },
        "gpu": {
            "name": detect_gpu_name(),
            "current_driver_version": driver_info["current_driver_version"],
            "current_driver_numeric": driver_info["current_driver_numeric"],
            "installed_branch": driver_info["installed_branch"],
            "recommended_branch": driver_info["recommended_branch"],
            "open_drivers": driver_info["rows"],
        },
        "cuda": {
            "latest_release": latest_release,
            "versions": cuda_versions,
        },
        "compatibility": compatibility,
        "sources": {
            "install_guide_url": INSTALL_GUIDE_URL,
            "release_notes_url": RELEASE_NOTES_URL,
            "archive_index_url": ARCHIVE_INDEX_URL,
            "latest_downloads_url": LATEST_DOWNLOADS_URL,
        },
    }
    json.dump(data, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
