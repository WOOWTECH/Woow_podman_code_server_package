"""Minimal QEMU guest agent client over the QEMU chardev unix socket (HAOS test VM on the runner)."""
import base64
import json
import random
import socket
import time


class GuestError(RuntimeError):
    pass


class Guest:
    def __init__(self, path):
        self.path = path

    def _call(self, message, timeout=60):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(self.path)
            stream = sock.makefile('rwb')
            token = random.randint(1, 2**31 - 1)
            # guest-sync-delimited flushes any stale bytes; the reply follows a 0xFF marker.
            stream.write(json.dumps({'execute': 'guest-sync-delimited', 'arguments': {'id': token}}).encode() + b'\n')
            stream.flush()
            while True:
                byte = stream.read(1)
                if not byte:
                    raise GuestError('QGA_CLOSED')
                if byte == b'\xff':
                    break
            while True:
                line = stream.readline()
                if not line:
                    raise GuestError('QGA_CLOSED')
                if json.loads(line).get('return') == token:
                    break
            stream.write(json.dumps(message).encode() + b'\n')
            stream.flush()
            reply = json.loads(stream.readline())
            if 'error' in reply:
                raise GuestError('QGA_' + str(reply['error'].get('class', 'ERROR')))
            return reply.get('return')

    def ping(self):
        try:
            self._call({'execute': 'guest-ping'}, timeout=5)
            return True
        except Exception:
            return False

    def run(self, argv, stdin=b'', timeout=600, env=None):
        """Run argv[0] (absolute path) in the guest; return (exit code, stdout bytes, stderr bytes)."""
        arguments = {'path': argv[0], 'arg': list(argv[1:]), 'capture-output': True}
        if env:
            arguments['env'] = [f'{k}={v}' for k, v in env.items()]
        if stdin:
            arguments['input-data'] = base64.b64encode(stdin).decode()
        pid = self._call({'execute': 'guest-exec', 'arguments': arguments})['pid']
        deadline = time.monotonic() + timeout
        delay = 0.05
        while True:
            status = self._call({'execute': 'guest-exec-status', 'arguments': {'pid': pid}})
            if status.get('exited'):
                return (status.get('exitcode', -1), base64.b64decode(status.get('out-data', '')),
                        base64.b64decode(status.get('err-data', '')))
            if time.monotonic() > deadline:
                raise GuestError('QGA_COMMAND_TIMEOUT')
            time.sleep(delay)
            delay = min(delay * 2, 1.0)

    def sh(self, script, stdin=b'', timeout=600, check=True):
        code, out, err = self.run(['/bin/sh', '-c', script], stdin=stdin, timeout=timeout)
        if check and code != 0:
            raise GuestError('GUEST_COMMAND_FAILED')
        return code, out, err
