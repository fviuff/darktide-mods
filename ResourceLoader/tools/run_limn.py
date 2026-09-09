"""run limn"""

import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIMN = ROOT / "tools/limn/limn.exe"
DICTIONARY = ROOT / "tools/limn/dictionary_hashcat_dt.txt"
DEFAULT_OUTPUT = ROOT / "limn-output"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--threads", type=int, default=0)
    args = parser.parse_args()

    if not LIMN.is_file():
        raise FileNotFoundError(f"Place limn.exe here: {LIMN}")
    if not DICTIONARY.is_file():
        raise FileNotFoundError(f"Place dictionary.txt here: {DICTIONARY}")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for pattern in ("*.package", "*.package.json"):
        for path in output.rglob(pattern):
            path.unlink()
    (output / "hashes.bin").unlink(missing_ok=True)

    common = [str(LIMN), "--dict", str(DICTIONARY)]
    if args.input:
        common += ["--input", str(args.input.resolve())]
    if args.threads > 0:
        common += ["--threads", str(args.threads)]

    subprocess.run(common + ["--output", str(output), "--dict-no-skip", "--dump-raw", "package"], check=True)
    subprocess.run(common + ["--dump-hashes"], cwd=output, check=True)
    print(f"Catalog source extracted to: {output}")


if __name__ == "__main__":
    main()
