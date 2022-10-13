import argparse
import zipfile

def _parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", required=True, help="File to extract")
    parser.add_argument("--dst", required=True, help="Output dir")

    return parser.parse_args()

def do_unzip(src, dst):
    z = zipfile.ZipFile(src)
    z.extractall(dst)

def main():
    args = _parse_args()
    do_unzip(args.src, args.dst)

if __name__ == "__main__":
    main()