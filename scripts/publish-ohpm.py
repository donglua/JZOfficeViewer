#!/usr/bin/env python3
import os
import pty
import select
import subprocess
import sys
import time

def main():
    if len(sys.argv) < 2:
        print("Usage: publish-ohpm.py <har_path>")
        sys.exit(1)

    har_path = sys.argv[1]
    passphrase = os.environ.get("OHPM_KEY_PASSPHRASE", "")

    if not passphrase:
        res = subprocess.run(["ohpm", "publish", har_path])
        sys.exit(res.returncode)

    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ["ohpm", "publish", har_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)

    time.sleep(1)
    os.write(master, (passphrase + "\r").encode())

    while proc.poll() is None:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                data = os.read(master, 1024)
                if not data:
                    break
                sys.stdout.buffer.write(data)
                sys.stdout.flush()
                if b"passphrase" in data.lower():
                    os.write(master, (passphrase + "\r").encode())
            except OSError:
                break

    os.close(master)
    proc.wait()
    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
