#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pkgserver.py — an HTTPS repository server for CactPkg.

Serves a package repository the way the `cactpkg` client expects:

    GET  /                  a browsable listing of the packages
    GET  /index             the repository index
    GET  /<file>.cpkg       a package artifact
    PUT  /publish/<file>.cpkg
                            publish an artifact (raw .cpkg body); it is
                            validated, stored, and the index is rebuilt

cactpkg refuses plain http:// repositories, so this server terminates TLS
itself (certificate + key files).  A second, optional plain-HTTP listener can
answer Let's Encrypt HTTP-01 challenges on port 80 while the package service
keeps running, so a certificate can be issued and renewed without downtime.

The .cpkg format lives in tools/cpkg.py, which this imports — one authority
for the format, not a second reader that can drift.

Usage:
  pkgserver.py --repo DIR --cert cert.pem --key key.pem [options]

Options (see --help): --host, --port, --acme-port, --acme-webroot, --domain,
--publish-token-file, --max-upload, --allow-overwrite, --reindex, --pidfile.
"""

import argparse
import hmac
import html
import http.server
import logging
import os
import signal
import ssl
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cpkg

log = logging.getLogger("pkgserver")

VERSION = "1.0"
INDEX_NAME = "index"
INDEX_HEADER = "# CactPkg repository index v1\n"
PUBLISH_PREFIX = "/publish/"
ACME_PREFIX = "/.well-known/acme-challenge/"
CHUNK = 64 * 1024


def artifact_name_ok(name):
    """True for a safe artifact file name: '<stem>.cpkg', no path parts.

    The stem must satisfy the manifest name rule and start alphanumeric, which
    also rejects '.', '..' and hidden files."""
    if not name or len(name) > 255 or "/" in name or "\\" in name:
        return False
    if not name.endswith(".cpkg"):
        return False
    stem = name[:-5]
    return bool(stem) and stem[0].isalnum() and cpkg.name_ok(stem)


def rebuild_index(repo):
    """Rewrite <repo>/index from the *.cpkg files, skipping unreadable ones.

    Mirrors `cpkg.py index` (name/version/file/depends, sorted by name), but a
    single corrupt artifact must not stop the server from updating the rest."""
    rows = []
    for fn in sorted(os.listdir(repo)):
        if not fn.endswith(".cpkg"):
            continue
        try:
            _text, meta, _entries = cpkg.read_cpkg(os.path.join(repo, fn))
        except cpkg.CpkgError as e:
            log.warning("index: %s: %s (skipped)", fn, e)
            continue
        rows.append((meta.get("name", fn), meta["version"], fn,
                     meta.get("depends", "")))
    rows.sort(key=lambda r: r[0])

    fd, tmp = tempfile.mkstemp(dir=repo, prefix=".index-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(INDEX_HEADER)
            for name, ver, fn, deps in rows:
                f.write("%s\t%s\t%s\t%s\n" % (name, ver, fn, deps))
        os.replace(tmp, os.path.join(repo, INDEX_NAME))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return len(rows)


def render_listing(repo):
    try:
        with open(os.path.join(repo, INDEX_NAME), "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []

    rows = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 3 and artifact_name_ok(fields[2]):
            rows.append((fields[0], fields[1], fields[2]))

    out = [
        "<!doctype html><html><head><meta charset=\"utf-8\">",
        "<title>CactPkg repository</title>",
        "<style>body{font-family:monospace;margin:2rem}"
        "table{border-collapse:collapse}"
        "td,th{padding:.2rem .8rem;border-bottom:1px solid #ccc;text-align:left}"
        "</style></head><body>",
        "<h1>CactPkg repository</h1>",
        "<p>%d package(s). Add it to a CactOS system with:</p>" % len(rows),
        "<pre>cactpkg update -R https://&lt;host&gt;</pre>",
        "<table><tr><th>name</th><th>version</th><th>file</th></tr>",
    ]
    for name, ver, fn in rows:
        efn = html.escape(fn)
        out.append("<tr><td>%s</td><td>%s</td><td><a href=\"/%s\">%s</a></td></tr>"
                   % (html.escape(name), html.escape(ver), efn, efn))
    out.append("</table></body></html>")
    return "".join(out).encode("utf-8")


class _BaseHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cactpkg-server/" + VERSION

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)

    def _send(self, code, ctype, body, head_only=False, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for key, val in (extra or ()):
            self.send_header(key, val)
        self.end_headers()
        if not head_only and body:
            self.wfile.write(body)

    def _text(self, code, message, head_only=False):
        self._send(code, "text/plain; charset=utf-8",
                   (message + "\n").encode("utf-8"), head_only)

    def _text_close(self, code, message, extra=None):
        """Respond and close the connection.

        For a request whose body was not consumed: on a keep-alive connection
        the leftover body would otherwise be parsed as the next request."""
        self.close_connection = True
        self._send(code, "text/plain; charset=utf-8",
                   (message + "\n").encode("utf-8"), extra=extra)

    def _file(self, path, ctype, head_only=False):
        try:
            f = open(path, "rb")
        except OSError:
            self._text(404, "not found", head_only)
            return
        with f:
            st = os.fstat(f.fileno())
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(st.st_size))
            self.send_header("Last-Modified", self.date_time_string(st.st_mtime))
            self.end_headers()
            if head_only:
                return
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)


class PkgHandler(_BaseHandler):
    @property
    def cfg(self):
        return self.server.cfg

    def do_GET(self):
        self._route(head_only=False)

    def do_HEAD(self):
        self._route(head_only=True)

    def do_POST(self):
        self._text_close(405, "method not allowed")

    def do_DELETE(self):
        self._text_close(405, "method not allowed")

    def _route(self, head_only):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8",
                       render_listing(self.cfg.repo), head_only)
            return
        if path == "/" + INDEX_NAME:
            self._file(os.path.join(self.cfg.repo, INDEX_NAME),
                       "text/plain; charset=utf-8", head_only)
            return
        if path.startswith(PUBLISH_PREFIX) or path.startswith(ACME_PREFIX):
            self._text(405, "method not allowed", head_only)
            return
        name = path[1:]
        if artifact_name_ok(name):
            self._file(os.path.join(self.cfg.repo, name),
                       "application/octet-stream", head_only)
            return
        self._text(404, "not found", head_only)

    def do_PUT(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith(PUBLISH_PREFIX):
            self._text_close(405, "only PUT /publish/<file>.cpkg is accepted")
            return
        name = path[len(PUBLISH_PREFIX):]
        if not artifact_name_ok(name):
            self._text_close(400, "bad package file name "
                                  "(want <name>-<version>.cpkg)")
            return
        if self.cfg.publish_token is None:
            self._text_close(403, "publishing is disabled "
                                  "(no --publish-token-file)")
            return
        if not self._authorized():
            self._text_close(401, "unauthorized",
                             extra=[("WWW-Authenticate", 'Bearer realm="cactpkg"')])
            return

        length = self.headers.get("Content-Length")
        if length is None:
            self._text_close(411, "Content-Length required")
            return
        try:
            length = int(length)
        except ValueError:
            self._text_close(400, "bad Content-Length")
            return
        if length <= 0:
            self._text_close(400, "empty body")
            return
        if length > self.cfg.max_upload:
            self._text_close(413, "package too large (limit is %d bytes)"
                             % self.cfg.max_upload)
            return
        self._receive_and_publish(name, length)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        return hmac.compare_digest(header[len(prefix):].strip(),
                                   self.cfg.publish_token)

    def _receive_and_publish(self, name, length):
        repo = self.cfg.repo
        dest = os.path.join(repo, name)
        fd, tmp = tempfile.mkstemp(dir=repo, prefix=".upload-", suffix=".part")
        try:
            remaining = length
            with os.fdopen(fd, "wb") as f:
                while remaining > 0:
                    chunk = self.rfile.read(min(CHUNK, remaining))
                    if not chunk:
                        self._text(400, "client closed the connection early")
                        return
                    f.write(chunk)
                    remaining -= len(chunk)

            try:
                _text, meta, _entries = cpkg.read_cpkg(tmp)
            except cpkg.CpkgError as e:
                self._text(400, "not a valid .cpkg: %s" % e)
                return
            except Exception as e:
                self._text(500, "internal error: %s" % e)
                return
            if not cpkg.name_ok(meta.get("name", "")):
                self._text(400, "manifest has an invalid package name")
                return

            if os.path.exists(dest) and not self.cfg.allow_overwrite:
                self._text(409, "%s already exists (server not built with "
                                "--allow-overwrite)" % name)
                return

            os.replace(tmp, dest)
            tmp = None
            os.chmod(dest, 0o644)
            with self.server.publish_lock:
                count = rebuild_index(repo)

            log.info("published %s (%s %s); repository now has %d package(s)",
                     name, meta.get("name"), meta.get("version"), count)
            body = ("published %s\t%s\t%s\t%d\n"
                    % (meta.get("name"), meta.get("version"), name, count))
            self._send(201, "text/plain; charset=utf-8", body.encode("utf-8"),
                       extra=[("Location", "/" + name)])
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass


class AcmeHandler(_BaseHandler):
    def do_GET(self):
        self._serve(head_only=False)

    def do_HEAD(self):
        self._serve(head_only=True)

    def do_POST(self):
        self._text_close(405, "method not allowed")

    def _serve(self, head_only=False):
        path = self.path.split("?", 1)[0]
        webroot = self.server.cfg.acme_webroot
        if path.startswith(ACME_PREFIX):
            token = path[len(ACME_PREFIX):]
            if webroot and token and "/" not in token and ".." not in token \
                    and len(token) <= 255:
                full = os.path.join(webroot, token)
                try:
                    with open(full, "rb") as f:
                        body = f.read()
                except OSError:
                    body = None
                if body is not None:
                    self._send(200, "application/octet-stream", body, head_only)
                    return
            self._text(404, "not found", head_only)
            return

        host = self.server.cfg.domain or self.headers.get("Host", "").split(":")[0]
        if host:
            self.send_response(301)
            self.send_header("Location", "https://%s%s" % (host, self.path))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._text(404, "not found", head_only)


class _ThreadingServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, cfg):
        self.cfg = cfg
        self.publish_lock = threading.Lock()
        self._ctx_lock = threading.Lock()
        self.ssl_context = None
        super().__init__(addr, handler)


class PkgServer(_ThreadingServer):
    def _build_context(self):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(self.cfg.cert, self.cfg.key)
        return ctx

    def install_context(self):
        """(Re)load the certificate; new connections use the new context."""
        ctx = self._build_context()
        with self._ctx_lock:
            self.ssl_context = ctx

    def process_request_thread(self, request, client_address):
        with self._ctx_lock:
            ctx = self.ssl_context
        try:
            request = ctx.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError) as e:
            log.debug("tls handshake from %s failed: %s",
                      client_address[0], e)
            try:
                self.shutdown_request(request)
            except OSError:
                pass
            return
        super().process_request_thread(request, client_address)


class Config(object):
    pass


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="pkgserver.py",
        description="HTTPS repository server for CactPkg.")
    p.add_argument("--repo", required=True,
                   help="repository directory (created if missing)")
    p.add_argument("--host", default="0.0.0.0", help="bind address")
    p.add_argument("--port", type=int, default=443, help="HTTPS port")
    p.add_argument("--cert", help="TLS certificate (PEM)")
    p.add_argument("--key", help="TLS private key (PEM)")
    p.add_argument("--acme-port", type=int, default=0,
                   help="plain-HTTP port for Let's Encrypt challenges "
                        "(0 = disabled)")
    p.add_argument("--acme-webroot",
                   help="directory certbot --webroot writes challenges to")
    p.add_argument("--domain", help="public name, used for the HTTP redirect "
                                    "and as the certificate identity")
    p.add_argument("--publish-token-file",
                   help="file holding the publish bearer token "
                        "(default: $CACTPKG_PUBLISH_TOKEN)")
    p.add_argument("--max-upload", type=int, default=64 * 1024 * 1024,
                   help="largest accepted artifact, in bytes")
    p.add_argument("--allow-overwrite", action="store_true",
                   help="let publish replace an existing artifact")
    p.add_argument("--reindex", action="store_true",
                   help="rebuild the index at startup")
    p.add_argument("--pidfile", help="write the PID here")
    p.add_argument("--log-level", default="INFO",
                   choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    p.add_argument("--version", action="version",
                   version="pkgserver " + VERSION)
    return p.parse_args(argv)


def read_token(path):
    if path:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    return os.environ.get("CACTPKG_PUBLISH_TOKEN", "").strip()


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=getattr(logging, args.log_level),
                        format="%(asctime)s %(levelname)s %(message)s",
                        stream=sys.stderr)

    if not args.cert or not args.key:
        log.error("--cert and --key are required: cactpkg only talks to "
                  "https://, so this server always terminates TLS")
        return 2
    for path in (args.cert, args.key):
        if not os.path.isfile(path):
            log.error("%s: no such file", path)
            return 2

    repo = os.path.abspath(args.repo)
    try:
        os.makedirs(repo, exist_ok=True)
    except OSError as e:
        log.error("cannot create %s: %s", repo, e)
        return 2

    try:
        token = read_token(args.publish_token_file) or None
    except OSError as e:
        log.error("cannot read %s: %s", args.publish_token_file, e)
        return 2
    if args.publish_token_file and not token:
        log.error("%s: empty publish token", args.publish_token_file)
        return 2

    cfg = Config()
    cfg.repo = repo
    cfg.cert = os.path.abspath(args.cert)
    cfg.key = os.path.abspath(args.key)
    cfg.acme_webroot = os.path.abspath(args.acme_webroot) if args.acme_webroot else None
    cfg.domain = args.domain
    cfg.publish_token = token
    cfg.max_upload = args.max_upload
    cfg.allow_overwrite = args.allow_overwrite

    if args.reindex:
        try:
            n = rebuild_index(repo)
        except OSError as e:
            log.error("cannot write the index in %s: %s", repo, e)
            return 2
        log.info("indexed %d package(s) in %s", n, repo)

    try:
        pkg_srv = PkgServer((args.host, args.port), PkgHandler, cfg)
    except OSError as e:
        log.error("cannot listen on %s:%d: %s", args.host, args.port, e)
        return 1
    pkg_srv.install_context()
    servers = [pkg_srv]

    if args.acme_port:
        try:
            servers.append(_ThreadingServer((args.host, args.acme_port),
                                            AcmeHandler, cfg))
        except OSError as e:
            log.error("cannot listen on %s:%d: %s",
                      args.host, args.acme_port, e)
            pkg_srv.server_close()
            return 1

    stop = threading.Event()

    def on_stop(signum, _frame):
        log.info("signal %d: shutting down", signum)
        stop.set()

    def on_reload(_signum, _frame):
        try:
            pkg_srv.install_context()
            log.info("reloaded the TLS certificate")
        except Exception as e:
            log.error("certificate reload failed: %s", e)

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    signal.signal(signal.SIGHUP, on_reload)

    if args.pidfile:
        with open(args.pidfile, "w", encoding="ascii") as f:
            f.write("%d\n" % os.getpid())

    for srv in servers:
        threading.Thread(target=srv.serve_forever,
                         name="serve", daemon=True).start()
    log.info("https listening on %s:%d", args.host, pkg_srv.server_address[1])
    if args.acme_port:
        log.info("http (acme) listening on %s:%d", args.host, args.acme_port)
    log.info("repository %s, publishing %s", repo,
             "enabled" if token else "disabled")

    try:
        while not stop.is_set():
            stop.wait(3600)
    finally:
        for srv in servers:
            srv.shutdown()
        for srv in servers:
            srv.server_close()
        if args.pidfile:
            try:
                os.unlink(args.pidfile)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
