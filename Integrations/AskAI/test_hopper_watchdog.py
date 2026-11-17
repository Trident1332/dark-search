"""Exercise the production helper lifecycle with an owned synthetic child only."""
import os
import json
import socket
import threading
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == 'darwin', 'macOS sandbox/process lifecycle test')
class HopperWatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='search-hw-', dir='/private/tmp')
        cls.root = Path(cls.directory.name).resolve()
        production = Path(__file__).with_name('HopperOfflineLauncher.swift').read_text()
        # Compile the real lifecycle classes, replacing only the Hopper/AE entry
        # point. This avoids introducing a synthetic execution mode in the app.
        lifecycle = production.split('private func launch() throws -> Int32 {', 1)[0]
        fixture = cls.root / 'watchdog.swift'
        fixture.write_text(lifecycle + '''
do {
    let child=try OwnedChild(binary:CommandLine.arguments[2],environment:ProcessInfo.processInfo.environment,scratch:CommandLine.arguments[1])
    print("CHILD \\(child.pid)");fflush(stdout)
    let result=child.wait()
    print("RESULT \\(result)");fflush(stdout)
    exit(result)
} catch { fputs("\\(error)\\n",stderr);exit(1) }
''')
        cls.executable = cls.root / 'watchdog'
        subprocess.run(['xcrun', 'swiftc', str(fixture), '-o', str(cls.executable)],
                       check=True, timeout=60, capture_output=True)
        cls.target = cls.root / 'synthetic-child'
        cls.target.write_text('#!/bin/sh\nexec /bin/sleep 30\n')
        cls.target.chmod(0o700)
        cls.launcher = cls.root / 'launcher'
        full_source = Path(__file__).with_name('HopperOfflineLauncher.swift')
        subprocess.run(['xcrun', 'swiftc', str(full_source), '-o', str(cls.launcher)],
                       check=True, timeout=60, capture_output=True)
        cls.app = cls.root / 'Hopper Disassembler.app'
        (cls.app / 'Contents/MacOS').mkdir(parents=True)
        import plistlib
        (cls.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.cryptic-apps.hopper-web-4'}))
        engine_source = cls.root / 'engine.c'
        engine_source.write_text('''#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
 int fd=socket(AF_INET,SOCK_STREAM,0); int networkError=errno;
 if(fd>=0) { struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(443),.sin_addr.s_addr=htonl(0xc0000201)};
  int result=connect(fd,(void*)&address,sizeof(address));networkError=result<0?errno:0;close(fd); }
 fd=open(getenv("TEST_FORBIDDEN"),O_RDONLY);int fileError=fd<0?errno:0;if(fd>=0)close(fd);
 fprintf(stderr,"synthetic network_errno=%d outside_errno=%d\\n",networkError,fileError);fflush(stderr);
 sleep(2);return 0;
}
''')
        subprocess.run(['xcrun', 'clang', str(engine_source), '-o',
                        str(cls.app / 'Contents/MacOS/Hopper Disassembler')],
                       check=True, timeout=60, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_original_parent_death_stops_owned_child_without_group_signal(self):
        scratch = self.root / 'scratch'
        scratch.mkdir(mode=0o700, exist_ok=True)
        supervisor_code = '''
import subprocess, sys
child = subprocess.Popen(sys.argv[1:], stdout=sys.stdout, stderr=sys.stderr)
print('MONITOR ' + str(child.pid), flush=True)
sys.exit(child.wait())
'''
        stderr_path = self.root / 'stderr.log'
        with stderr_path.open('wb') as errors:
            supervisor = subprocess.Popen([sys.executable, '-u', '-c', supervisor_code,
                                           str(self.executable), str(scratch), str(self.target)],
                                          stdout=subprocess.PIPE, stderr=errors,
                                          start_new_session=True, bufsize=0)
            pending = b''
            lines = []

            def until(prefix, timeout=5):
                nonlocal pending
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    for line in lines:
                        if line.startswith(prefix):
                            return line
                    ready, _, _ = select.select([supervisor.stdout], [], [],
                                                max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    data = os.read(supervisor.stdout.fileno(), 4096)
                    if not data:
                        break
                    pending += data
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        lines.append(line.decode())
                self.fail('Expected ' + prefix + '; output=' + repr(lines) +
                          '; stderr=' + stderr_path.read_text())

            child_pid = monitor_pid = None
            try:
                monitor_pid = int(until('MONITOR ').split()[1])
                child_pid = int(until('CHILD ').split()[1])
                # It remains alive while its actual parent lives; no accidental
                # timer expiry should terminate a healthy analysis session.
                time.sleep(0.8)
                os.kill(child_pid, 0)
                os.kill(monitor_pid, 0)
                # Kill just the supervisor PID, never the process group. The
                # orphaned helper must discover the loss without a signal.
                supervisor.kill()
                supervisor.wait(timeout=2)
                self.assertEqual(until('RESULT '), 'RESULT 137')
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
                self.assertIn('analysis supervisor exited', stderr_path.read_text())
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait(timeout=2)
                # These are this test's exclusively owned descendants only.
                for pid in [monitor_pid, child_pid]:
                    if pid:
                        try: os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                supervisor.stdout.close()


    def test_single_sandbox_relay_preserves_child_network_and_file_denials(self):
        self.exercise_relay({'version': 1, 'ok': True}, expected_exit=0)

    def test_host_denial_is_reported_and_owned_child_is_reaped(self):
        result = self.exercise_relay({'version': 1, 'ok': False,
                                     'error': 'Synthetic host authorization denied'},
                                    expected_exit=1)
        self.assertIn('Synthetic host authorization denied', result.stderr)

    def exercise_relay(self, response, expected_exit):
        case = Path(tempfile.mkdtemp(prefix='relay-', dir=self.root))
        workspace = case / 'workspace'
        scratch = case / 'scratch'
        workspace.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
        target = workspace / 'target'
        target.write_text('synthetic analysis input')
        bridge = scratch / 'bootstrap.py'
        bridge.write_text('# synthetic bridge; never executed by this test\n')
        outside = case / 'outside.txt'
        outside.write_text('must remain unreadable')
        control = scratch / 'hopper-events.sock'
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(control))
        control.chmod(0o600)
        server.listen(1)
        server.settimeout(5)
        captured = {}
        errors = []

        def serve():
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(5)
                    received = b''
                    while b'\n' not in received:
                        part = connection.recv(2048)
                        if not part or len(received) > 16384:
                            raise AssertionError('missing or oversized relay request')
                        received += part
                    captured.update(json.loads(received.split(b'\n')[0]))
                    connection.sendall(json.dumps(response).encode() + b'\n')
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        quoted = lambda path: json.dumps(str(path))
        reads = ' '.join('(subpath ' + quoted(path) + ')' for path in
                         ['/System', '/usr/lib', '/usr/bin', '/bin', '/private/var/db/dyld',
                          workspace, scratch, self.app])
        profile = '''(version 1)
(deny default)
(allow process-fork)
(allow process-exec)
(allow signal (target children))
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read-data (literal "/"))
(allow file-read* READS (literal LAUNCHER) (literal "/dev/null") (literal "/dev/urandom"))
(allow file-write* (subpath SCRATCH) (literal "/dev/null"))
(deny network*)
(deny appleevent-send)
(deny lsopen)
(allow network-bind (local unix-socket (subpath SCRATCH)))
(allow network-inbound (local unix-socket (subpath SCRATCH)))
(allow network-outbound (remote unix-socket (subpath SCRATCH)))
'''.replace('READS', reads).replace('LAUNCHER', quoted(self.launcher)).replace('SCRATCH', quoted(scratch))
        environment = {'PATH': '/usr/bin:/bin', 'HOME': str(scratch),
                       'TMPDIR': str(scratch) + '/', 'SEARCH_HOPPER_ISOLATED': '1',
                       'SEARCH_HOPPER_APPLICATION': str(self.app),
                       'SEARCH_HOPPER_WORKSPACE': str(workspace),
                       'SEARCH_HOPPER_CONTROL_SOCKET': str(control),
                       'SEARCH_HOPPER_CONTROL_TOKEN': 'a' * 64,
                       'TEST_FORBIDDEN': str(outside)}
        try:
            result = subprocess.run(['/usr/bin/sandbox-exec', '-p', profile,
                                     str(self.launcher), '--analysis', '-e', str(target),
                                     '-Y', str(bridge), '-l', 'Mach-O'],
                                    env=environment, cwd=workspace, timeout=8,
                                    capture_output=True, text=True)
            thread.join(timeout=1)
            self.assertEqual(errors, [])
            self.assertEqual(result.returncode, expected_exit, result.stderr)
            self.assertEqual(captured['version'], 1)
            self.assertEqual(captured['token'], 'a' * 64)
            self.assertEqual(captured['targetPath'], str(target))
            self.assertEqual(captured['bridgePath'], str(bridge))
            self.assertTrue(captured['analysis'])
            self.assertEqual(captured['loaders'], ['Mach-O'])
            self.assertGreater(captured['hopperStartedSec'], 0)
            if expected_exit == 0:
                self.assertIn('network_errno=1 outside_errno=1', result.stderr)
            with self.assertRaises(ProcessLookupError):
                os.kill(captured['hopperPID'], 0)
            return result
        finally:
            server.close()


if __name__ == '__main__':
    unittest.main()
