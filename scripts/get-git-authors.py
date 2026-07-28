#!/usr/bin/env python3

import argparse
import collections
import pathlib
import subprocess
import sys


def run_git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=check,
    )


def get_repo_root() -> pathlib.Path:
    result = run_git("rev-parse", "--show-toplevel")
    return pathlib.Path(result.stdout.strip())


def get_tracked_files(target: str) -> list[str]:
    result = run_git("ls-files", "-z", "--", target)

    return [
        path
        for path in result.stdout.split("\0")
        if path
    ]


def is_binary_file(path: pathlib.Path) -> bool:
    try:
        with path.open("rb") as file:
            chunk = file.read(8192)
    except OSError:
        return True

    return b"\0" in chunk


def blame_authors(path: str):
    process = subprocess.Popen(
        ["git", "blame", "--line-porcelain", "--", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    assert process.stdout is not None

    for line in process.stdout:
        if line.startswith("author "):
            yield line.removeprefix("author ").rstrip("\n")

    return_code = process.wait()

    if return_code != 0:
        raise subprocess.CalledProcessError(
            return_code,
            process.args,
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Show Git line ownership statistics."
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Tracked file or directory to analyse (default: current directory)",
    )
    args = parser.parse_args()

    try:
        repo_root = get_repo_root()
        files = get_tracked_files(args.path)
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip() if error.stderr else str(error)
        print(f"Git error: {message}", file=sys.stderr)
        return 1

    if not files:
        print(f"No tracked files found for: {args.path}", file=sys.stderr)
        return 1

    authors: collections.Counter[str] = collections.Counter()

    processed_files = 0
    skipped_binary = 0
    skipped_failed = 0

    for relative_path in files:
        absolute_path = repo_root / relative_path

        if not absolute_path.is_file():
            continue

        if is_binary_file(absolute_path):
            skipped_binary += 1
            continue

        try:
            authors.update(blame_authors(relative_path))
            processed_files += 1
        except subprocess.CalledProcessError:
            skipped_failed += 1

    total_lines = authors.total()

    if total_lines == 0:
        print("No blameable text lines found.", file=sys.stderr)
        return 1

    author_width = max(
        30,
        max(len(author) for author in authors),
    )

    print()
    print(
        f"{'Author':<{author_width}} "
        f"{'Lines':>12} "
        f"{'Percent':>10}"
    )
    print("-" * (author_width + 24))

    for author, line_count in authors.most_common():
        percentage = line_count / total_lines * 100

        print(
            f"{author:<{author_width}} "
            f"{line_count:>12,} "
            f"{percentage:>9.2f}%"
        )

    print()
    print(f"Processed files:     {processed_files:,}")
    print(f"Skipped binary:      {skipped_binary:,}")
    print(f"Skipped blame errors:{skipped_failed:>7,}")
    print(f"Total blamed lines:  {total_lines:,}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
