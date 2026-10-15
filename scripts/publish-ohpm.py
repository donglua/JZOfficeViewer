#!/usr/bin/env python3
import os
import pty
import select
import subprocess
import sys
import time

try:
    import termios
except ImportError:
    termios = None

TIMEOUT_SECONDS = 300  # 5 minutes safety limit

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

    # Disable terminal echo on the slave PTY so that typed passphrase characters
    # are never reflected back into the master output stream or stdout logs.
    if termios is not None:
        try:
            attrs = termios.tcgetattr(slave)
            attrs[3] &= ~termios.ECHO
            termios.tcsetattr(slave, termios.TCSANOW, attrs)
        except Exception:
            pass

    proc = subprocess.Popen(
        ["ohpm", "publish", har_path],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)

    sent = False
    output = b""
    start_time = time.time()

    try:
        while True:
            if time.time() - start_time > TIMEOUT_SECONDS:
                print(
                    f"\n[publish-ohpm] Timed out waiting for ohpm publish (limit: {TIMEOUT_SECONDS}s)",
                    file=sys.stderr,
                )
                proc.kill()
                break

            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    data = os.read(master, 1024)
                    if not data:
                        break
                    output += data
                    sys.stdout.buffer.write(data)
                    sys.stdout.flush()

                    # When ohpm prompts for passphrase, send characters one by one with a small delay.
                    # In raw mode, ohpm's readline unhooks the data listener on newline before reading
                    # if characters are sent in a single chunk.
                    if not sent and b"passphrase" in output.lower():
                        time.sleep(0.3)
                        for ch in passphrase:
                            os.write(master, ch.encode())
                            time.sleep(0.05)
                        time.sleep(0.1)
                        os.write(master, b"\r")
                        sent = True
                except OSError:
                    break
            elif proc.poll() is not None:
                # Process exited and no buffered data left in master
                break
    finally:
        os.close(master)

    proc.wait()
    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
