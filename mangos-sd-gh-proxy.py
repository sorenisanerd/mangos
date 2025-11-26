#!/usr/bin/env python3
import re
import json
from urllib import request
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

sha256sums = {}

def os_release_to_dict(fname='/usr/lib/os-release'):
    result = {}
    with open(fname, 'r') as fp:
        for l in fp:
            if '=' in l:
                key, value = l.split('=', 1)
                result[key.strip()] = value.strip().strip('"')
    return result


os_release = os_release_to_dict()

github_url = 'https://github.com/Mastercard/mangos'

if 'MANGOS_GITHUB_URL' in os_release:
    github_url = os_release['MANGOS_GITHUB_URL']

default_repo_full = '/'.join(github_url.split('/')[-2:])


class MangosHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        global sha256sums
        parsed_path = urlparse(self.path)
        path = parsed_path.path.lstrip('/')
        matches = re.match('^([^/]*/[^/]*)/[^/]*$', path)

        if matches:
            repo_full = matches.group(1)
        else:
            if "MKOSI_SERVE_URL" in os_release:
                url = f'{os_release["MKOSI_SERVE_URL"]}/{path}'
                self.send_response(302)
                self.send_header('Location', url)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            repo_full = default_repo_full

        if path.endswith('SHA256SUMS'):
            if not repo_full in sha256sums:
                url = f'https://api.github.com/repos/{repo_full}/releases'
                with request.urlopen(url) as resp:
                    data = json.load(resp)
                sha256sums[repo_full] = ''
                for release in data:
                    for asset in release['assets']:
                        digest = asset.get("digest", "")
                        name = asset.get("name", "")
                        if name.endswith('sigbundle'):
                            continue
                        if digest.startswith("sha256:"):
                            sha256sums[repo_full] += f'{digest[7:]} *{name}\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')

            body_bytes = sha256sums[repo_full].encode()
            self.send_header('Content-Length', str(len(body_bytes)))
            self.end_headers()

            self.wfile.write(body_bytes)
            return

        # Handle file redirect
        filename = path.split('/')[-1]
        version = filename.split('_')[1] if '_' in filename else filename
        if version.endswith('.sigbundle'):
            version = version[:-10]
        for ext in ['.gz', '.zst']:
            if version.endswith(ext):
                version = version[:-len(ext)]
                break
        for ext in ['.tar', '.efi', '.cyclonedx.json', '.github.json', '.raw', '.spdx.json', '.syft.json']:
            if version.endswith(ext):
                version = version[:-len(ext)]
                break
        version = re.sub(r'\.root-x86-64(-verity(-sig)?)?\.[a-z0-9]{32}$', '', version)

        redirect_url = f'https://github.com/{repo_full}/releases/download/v{version}/{filename}'
        self.send_response(302)
        self.send_header('Location', redirect_url)
        self.send_header('Content-Length', '0')
        self.end_headers()

def main():
    server_address = ('0.0.0.0', 1002)
    httpd = HTTPServer(server_address, MangosHandler)
    print(f"Serving on {server_address[0]}:{server_address[1]}")
    httpd.serve_forever()

if __name__ == "__main__":
    main()
