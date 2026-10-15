"""Administer the test relay through the existing split proxy; never logs keys."""
import argparse
from pathlib import Path
import socket
import sys

import paramiko

from cloud_configuration import deployment

CONFIG = deployment()
HOST = CONFIG['host']


def connect():
    try:
        if not CONFIG.get('proxy_host') or not CONFIG['proxy_port']:
            raise ConnectionRefusedError()
        sock = socket.create_connection((CONFIG['proxy_host'], CONFIG['proxy_port']), timeout=15)
        sock.sendall(f'CONNECT {HOST}:{CONFIG["ssh_port"]} HTTP/1.1\r\nHost: {HOST}:{CONFIG["ssh_port"]}\r\n\r\n'.encode())
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            b = sock.recv(1)
            if not b or len(header) > 8192:
                sock.close()
                raise RuntimeError('Invalid local proxy response')
            header.extend(b)
        if header.split(b'\r\n', 1)[0].split()[1] != b'200':
            sock.close()
            raise RuntimeError('Local split proxy refused SSH')
    except ConnectionRefusedError:
        sock = socket.create_connection((HOST, CONFIG['ssh_port']), timeout=15)
    client = paramiko.SSHClient()
    client.load_host_keys(str(Path.home() / '.ssh/known_hosts'))
    client.connect(HOST, port=CONFIG['ssh_port'], username=CONFIG['ssh_user'],
                   key_filename=str(Path(CONFIG['ssh_key']).expanduser()),
                   sock=sock, timeout=20, banner_timeout=20, auth_timeout=20,
                   allow_agent=False, look_for_keys=False)
    client.get_transport().set_keepalive(15)
    return client


def run(client, command, timeout=120):
    _, stdout, stderr = client.exec_command(command, timeout=timeout)
    # Drain both streams while running to avoid filling SSH channel buffers.
    import time
    channel = stdout.channel
    deadline = time.monotonic() + timeout
    while True:
        if channel.recv_ready():
            sys.stdout.buffer.write(channel.recv(32768)); sys.stdout.buffer.flush()
        if channel.recv_stderr_ready():
            sys.stderr.buffer.write(channel.recv_stderr(32768)); sys.stderr.buffer.flush()
        if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
            return channel.recv_exit_status()
        if time.monotonic() > deadline:
            channel.close()
            raise TimeoutError('Remote command timed out; inspect remote state before retrying mutations')
        time.sleep(0.05)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--command')
    parser.add_argument('--upload', nargs=2, metavar=('LOCAL', 'REMOTE'))
    args = parser.parse_args()
    client = connect()
    try:
        if args.upload:
            with client.open_sftp() as sftp:
                sftp.put(*args.upload)
            print('File uploaded.')
        if args.command:
            sys.exit(run(client, args.command))
    finally:
        client.close()
