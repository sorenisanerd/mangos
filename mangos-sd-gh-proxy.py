#!/usr/bin/env python3
import re
import json
from urllib import request
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

sha256sums = ''

def os_release_to_dict(fname='/usr/lib/os-release'):
    result = {}
    with open(fname, 'r') as fp:
        for l in fp:
            if '=' in l:
                key, value = l.split('=', 1)
                result[key.strip()] = value.strip().strip('"')
    return result


os_release = os_release_to_dict()


if 'MANGOS_GITHUB_URL' in os_release:
    github_url = os_release['MANGOS_GITHUB_URL']
    repo_full = '/'.join(github_url.split('/')[-2:])


class MangosHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        global sha256sums
        parsed_path = urlparse(self.path)
        path = parsed_path.path.lstrip('/')

# /usr/lib/systemd/systemd-sysupdate
# journalctl -u mangos-sd-gh-proxy.service

        if path == 'SHA256SUMS':
            if not sha256sums:
                url = f'https://api.github.com/repos/{repo_full}/releases'
                with request.urlopen(url) as resp:
                    data = json.load(resp)
                for release in data:
                    for asset in release['assets']:
                        digest = asset.get("digest", "")
                        name = asset.get("name", "")
                        if digest.startswith("sha256:"):
                            sha256sums += f'{digest[7:]} *{name}\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(sha256sums.encode())
            return

        # Handle file redirect
        filename = path
        version = filename.split('_')[1] if '_' in filename else filename
        for ext in ['.gz', '.zst']:
            if version.endswith(ext):
                version = version[:-len(ext)]
                break
        for ext in ['.efi', '.cyclonedx.json', '.github.json', '.raw', '.spdx.json', '.syft.json']:
            if version.endswith(ext):
                version = version[:-len(ext)]
                break
        version = re.sub(r'\.root-x86-64(-verity(-sig)?)?\.[a-z0-9]{32}$', '', version)

        redirect_url = f'{github_url}/releases/download/v{version}/{filename}'
        self.send_response(302)
        self.send_header('Location', redirect_url)
        self.end_headers()

def main():
    server_address = ('0.0.0.0', 1002)
    httpd = HTTPServer(server_address, MangosHandler)
    print(f"Serving on {server_address[0]}:{server_address[1]}")
    httpd.serve_forever()

if __name__ == "__main__":
    main()
