#!/usr/bin/env python3
"""Live log of the iOS app over USB: the app started with DM_LOG_PORT=<port> serves its log on 127.0.0.1:<port> (ios/Sources/main.m); forward the
port with iproxy (libimobiledevice: iproxy <local port> <port>), then:
  logport.py tail <local port> [file]     print (and append to file) everything the app has logged so far and every new line, until it exits
  logport.py dump <local port>            make the app write a state dump (threads, graphics waits) into its log
  logport.py quit <local port>            make the app exit cleanly; waits for its acknowledgement
Lines go out only after the app replays its log so far, so nothing is missed."""
import socket, sys, time

def connect(port, timeout=3.0):
    s = socket.create_connection(('127.0.0.1', port), timeout=timeout); s.settimeout(None); return s

def tail(port, path=None):
    s = connect(port); out = open(path, 'ab') if path else None
    try:
        while True:
            b = s.recv(65536)
            if not b: break
            sys.stdout.buffer.write(b); sys.stdout.flush()
            if out: out.write(b); out.flush()
    except KeyboardInterrupt: pass
    finally: s.close()

def command(port, cmd, ack=None, limit=10.0):
    s = connect(port); s.settimeout(0.5); s.sendall(cmd.encode() + b'\n'); end = time.time() + limit; got = b''
    while time.time() < end:
        try: b = s.recv(65536)
        except socket.timeout: continue
        if not b: break   # the app closed the connection (exited)
        got += b
        if ack and ack in got: break
    s.close(); return ack is None or ack in got

if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit(__doc__)
    op, port = sys.argv[1], int(sys.argv[2])
    if op == 'tail': tail(port, sys.argv[3] if len(sys.argv) > 3 else None)
    elif op == 'dump': command(port, 'dump', limit=2.0)
    elif op == 'quit': sys.exit(0 if command(port, 'quit', b'DM_LOG_PORT: quit received') else 1)
    else: sys.exit(__doc__)
