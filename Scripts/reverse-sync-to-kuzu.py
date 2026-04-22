#!/usr/bin/env python3
"""
Reverse sync: kuzu-swift inline sources → gboyraz/kuzu

This script copies modified C/C++ source files from the kuzu-swift inline
directory (Sources/cxx-kuzu/kuzu/) back to the kuzu repository.

It is the inverse of collect-kuzu-src.py which copies kuzu → kuzu-swift.

Usage:
    python3 reverse-sync-to-kuzu.py [--kuzu-path PATH] [--dry-run] [--verbose]

    If --kuzu-path is not provided, it expects the kuzu repo to be at
    ../../kuzu relative to the kuzu-swift root (sibling directory), or
    you can set the KUZU_REPO_PATH environment variable.
"""

import os
import sys
import shutil
import argparse
import logging
import filecmp
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# File extensions that are part of the sync (matches collect-kuzu-src.py)
FILE_TYPES = {".c", ".h", ".cpp", ".hpp", ".cxx", ".hxx", ".cc", ".hh", ".tcc"}

# Directories/paths to SKIP during reverse sync (build artifacts, cmake-generated)
SKIP_PATHS = {"build"}


def get_kuzu_swift_root() -> Path:
    """Get the kuzu-swift project root directory."""
    # This script lives in Scripts/reverse-sync-to-kuzu.py
    script_dir = Path(__file__).resolve().parent
    root = script_dir.parent
    if not (root / "Package.swift").exists():
        logger.error("Cannot find kuzu-swift root (no Package.swift found at %s)", root)
        sys.exit(1)
    return root


def resolve_kuzu_path(kuzu_path_arg: str | None) -> Path:
    """Resolve the path to the kuzu repository."""
    if kuzu_path_arg:
        p = Path(kuzu_path_arg).resolve()
    elif os.environ.get("KUZU_REPO_PATH"):
        p = Path(os.environ["KUZU_REPO_PATH"]).resolve()
    else:
        # Default: sibling directory to kuzu-swift
        kuzu_swift_root = get_kuzu_swift_root()
        p = kuzu_swift_root.parent / "kuzu"

    if not p.exists():
        logger.error("Kuzu repo path does not exist: %s", p)
        sys.exit(1)
    if not (p / "src").exists():
        logger.error("Kuzu repo path does not look like a kuzu repo (no src/): %s", p)
        sys.exit(1)
    return p


def should_skip(relative_path: Path) -> bool:
    """Check if a path should be skipped during reverse sync."""
    parts = relative_path.parts
    if not parts:
        return True
    # Skip build artifacts
    if parts[0] in SKIP_PATHS:
        return True
    return False


def is_syncable_file(filepath: Path) -> bool:
    """Check if a file is a C/C++ source/header file."""
    return filepath.suffix.lower() in FILE_TYPES


def collect_source_files(source_dir: Path) -> dict[Path, Path]:
    """
    Collect all syncable files from the inline kuzu source directory.
    Returns a dict mapping relative_path → absolute_path.
    """
    files = {}
    for abs_path in source_dir.rglob("*"):
        if not abs_path.is_file():
            continue
        rel_path = abs_path.relative_to(source_dir)
        if should_skip(rel_path):
            continue
        if not is_syncable_file(abs_path):
            continue
        files[rel_path] = abs_path
    return files


def sync_files(
    source_files: dict[Path, Path],
    kuzu_path: Path,
    dry_run: bool = False,
    verbose: bool = False,
) -> dict:
    """
    Sync files from kuzu-swift inline sources to the kuzu repo.
    Returns statistics about the sync operation.
    """
    stats = {
        "copied": [],
        "unchanged": [],
        "new": [],
        "errors": [],
    }

    for rel_path, src_abs_path in sorted(source_files.items()):
        dest_path = kuzu_path / rel_path

        if dest_path.exists():
            # File exists in kuzu — check if it differs
            if filecmp.cmp(src_abs_path, dest_path, shallow=False):
                stats["unchanged"].append(rel_path)
                if verbose:
                    logger.debug("UNCHANGED: %s", rel_path)
                continue
            else:
                stats["copied"].append(rel_path)
                logger.info("MODIFIED:  %s", rel_path)
        else:
            stats["new"].append(rel_path)
            logger.info("NEW:       %s", rel_path)

        if not dry_run:
            try:
                dest_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_abs_path, dest_path)
            except Exception as e:
                logger.error("ERROR copying %s: %s", rel_path, e)
                stats["errors"].append((rel_path, str(e)))

    return stats


def sync_header(kuzu_swift_root: Path, kuzu_path: Path, dry_run: bool = False) -> bool:
    """
    Sync kuzu.h header file.
    Sources/cxx-kuzu/include/kuzu.h → kuzu/src/include/c_api/kuzu.h
    """
    src = kuzu_swift_root / "Sources" / "cxx-kuzu" / "include" / "kuzu.h"
    dest = kuzu_path / "src" / "include" / "c_api" / "kuzu.h"

    if not src.exists():
        logger.warning("kuzu.h not found at %s", src)
        return False

    if dest.exists() and filecmp.cmp(src, dest, shallow=False):
        logger.info("kuzu.h: UNCHANGED")
        return False

    if dest.exists():
        logger.info("kuzu.h: MODIFIED")
    else:
        logger.info("kuzu.h: NEW")

    if not dry_run:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)

    return True


def detect_deleted_files(
    source_files: dict[Path, Path],
    kuzu_path: Path,
) -> list[Path]:
    """
    Detect files that exist in kuzu but not in kuzu-swift inline sources.
    Only checks directories that are part of the sync (src/, extension/, third_party/).
    """
    deleted = []
    sync_dirs = ["src", "extension", "third_party"]

    for sync_dir in sync_dirs:
        kuzu_dir = kuzu_path / sync_dir
        if not kuzu_dir.exists():
            continue
        for abs_path in kuzu_dir.rglob("*"):
            if not abs_path.is_file():
                continue
            if not is_syncable_file(abs_path):
                continue
            rel_path = abs_path.relative_to(kuzu_path)
            if rel_path not in source_files:
                deleted.append(rel_path)

    return deleted


def main():
    parser = argparse.ArgumentParser(
        description="Reverse sync kuzu-swift inline sources → kuzu repo"
    )
    parser.add_argument(
        "--kuzu-path",
        type=str,
        default=None,
        help="Path to the kuzu repository (default: sibling dir or KUZU_REPO_PATH env)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Show unchanged files too",
    )
    parser.add_argument(
        "--detect-deleted",
        action="store_true",
        help="Detect files that exist in kuzu but not in kuzu-swift (won't delete them)",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    kuzu_swift_root = get_kuzu_swift_root()
    kuzu_path = resolve_kuzu_path(args.kuzu_path)
    inline_source_dir = kuzu_swift_root / "Sources" / "cxx-kuzu" / "kuzu"

    logger.info("kuzu-swift root:    %s", kuzu_swift_root)
    logger.info("kuzu repo:          %s", kuzu_path)
    logger.info("Inline source dir:  %s", inline_source_dir)

    if args.dry_run:
        logger.info("*** DRY RUN — no files will be modified ***")

    if not inline_source_dir.exists():
        logger.error("Inline source directory does not exist: %s", inline_source_dir)
        sys.exit(1)

    # Collect source files
    logger.info("Collecting source files...")
    source_files = collect_source_files(inline_source_dir)
    logger.info("Found %d syncable files", len(source_files))

    # Sync C/C++ sources
    logger.info("Syncing source files...")
    stats = sync_files(source_files, kuzu_path, dry_run=args.dry_run, verbose=args.verbose)

    # Sync kuzu.h header
    logger.info("Syncing kuzu.h header...")
    header_changed = sync_header(kuzu_swift_root, kuzu_path, dry_run=args.dry_run)

    # Detect deleted files if requested
    deleted_files = []
    if args.detect_deleted:
        logger.info("Detecting deleted files...")
        deleted_files = detect_deleted_files(source_files, kuzu_path)
        for f in deleted_files:
            logger.warning("DELETED in kuzu-swift (still in kuzu): %s", f)

    # Summary
    logger.info("=" * 60)
    logger.info("SYNC SUMMARY")
    logger.info("=" * 60)
    logger.info("  Total files scanned:  %d", len(source_files))
    logger.info("  Modified:             %d", len(stats["copied"]))
    logger.info("  New:                  %d", len(stats["new"]))
    logger.info("  Unchanged:            %d", len(stats["unchanged"]))
    logger.info("  Errors:               %d", len(stats["errors"]))
    logger.info("  kuzu.h changed:       %s", "Yes" if header_changed else "No")
    if args.detect_deleted:
        logger.info("  Deleted in kuzu-swift: %d", len(deleted_files))
    logger.info("=" * 60)

    if stats["errors"]:
        logger.error("Errors occurred during sync:")
        for path, err in stats["errors"]:
            logger.error("  %s: %s", path, err)
        sys.exit(1)

    total_changes = len(stats["copied"]) + len(stats["new"]) + (1 if header_changed else 0)
    if total_changes == 0:
        logger.info("No changes to sync.")
    else:
        logger.info("Successfully synced %d file(s).", total_changes)

    return 0


if __name__ == "__main__":
    sys.exit(main())
