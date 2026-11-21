# CactPkg

<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-blue.svg?style=for-the-badge" alt="License: GPLv3">
  <img src="https://img.shields.io/badge/arch-x86_64-red.svg?style=for-the-badge" alt="Arch: x86_64">
  <img src="https://img.shields.io/badge/language-C%2FPython-orange.svg?style=for-the-badge" alt="Language: C/Python">
  <img src="https://img.shields.io/badge/status-2.0.0-yellow.svg?style=for-the-badge" alt="Status: 2.0.0">
</p>

**The package manager of CactOS.** It runs entirely inside the OS. A package
source is either a repository directory (in the image:
`/usr/lib/cactpkg/repo`) or a **remote repository over HTTPS** — the index and
`.cpkg` artifacts are downloaded into a local cache (TLS 1.3 and certificate
verification come from libc, keys stay in the process). Plain `http://` is
refused.

## Status (2.0.0)

- [x] Directory packages (`pkg/<name>/` = `manifest` + `payload/`)
- [x] `.cpkg` v1 artifact + host-side tool `tools/cpkg.py`
- [x] Repository index (`index`) and the offline repository baked into the image
- [x] Base-system programs packaged automatically: the image build wraps every
      tool in `/usr/bin` and `/usr/sbin` as a `.cpkg` (`cpkg.py sysrepo`), so
      `cactpkg search`/`update` lists the whole base system, not just add-ons
- [x] Linux-style command set: `update`, `install` (with dependencies),
      `remove` (with a dependents check), `list`, `search`, `info`, `files`
- [x] Persistent installs into a prefix (default `/usr/local`), config in
      `/etc/cactpkg.conf`, database in `/var/lib/cactpkg`
- [x] Remote repositories over HTTPS: the index is fetched by `update`,
      artifacts on install, both cached under `/var/cache/cactpkg`
- [x] A server for hosting a repository: `tools/pkgserver.py` (HTTPS, with a
      publish endpoint and a Let's Encrypt challenge listener)
- [ ] `.cpkg` integrity checks (CRC/signature)
- [ ] Versions and conflicts

## Building

Requires built sibling trees of **CactLibc-x86_64** (`clibc.so`, `ld.so`,
`start.o`) - auto-detected by default:

```sh
ninja -C build-meson             # build-meson/cactpkg + build-meson/hello (demo)
ninja -C build-meson repo        # build the personal offline repository in repo/ (.cpkg + index)
ninja -C build-meson check       # validate packages and dump .cpkg
ninja -C build-meson stage       # bake cactpkg and repo/ into the LocalRepoCactOS tree
```

`ninja -C build-meson stage` places:

- `/usr/sbin/cactpkg` - the manager,
- `/usr/lib/cactpkg/repo/{*.cpkg,index}` - the personal offline repository.

The regular image build then packs them into `cctkfs.img`:

```sh
ninja -C CactOS-x86_64/build-meson iso   # or: ninja -C LocalRepoCactOS-x86_64/build-meson stage
```

Since the LocalRepo build gained a `cactpkg` step, the manager and its
offline repository are re-baked into the image on every build, even after a
`ninja -C build-meson clean`.

## Usage inside CactOS

The manager lives in `/usr/sbin`, and the offline repository is available by
default (`/usr/lib/cactpkg/repo`):

```
cactpkg update                  # refresh repository indexes
cactpkg search hello            # search
cactpkg install hello           # install a package from the repository (with dependencies)
cactpkg install ./pkg.cpkg      # install from a file
cactpkg list                    # installed packages
cactpkg info cactpkg            # package details
cactpkg files hello             # files of an installed package
cactpkg remove hello            # remove
```

A remote repository is a `repo` entry that is an **https://** URL (or `-R <url>`);
it must serve an `index` and the `.cpkg` files it names. Plain `http://` is
refused — an unauthenticated index or artifact would be a trivial MITM:

```
cactpkg update -R https://packages.example.org/x86_64          # fetch the index over the network
cactpkg install -R https://packages.example.org/x86_64 hello   # download and install a package
```

Files are installed into the prefix (default `/usr/local`) and persist on
disk. Configuration: `/etc/cactpkg.conf` (`prefix`, `db`, `cache`, repeatable
`repo`, `arch`), created with documented defaults on first run; overridable with
`--prefix`, `-R/--repo`, `--cache`, `-C/--conf`.

## Serving a repository over HTTPS

`tools/pkgserver.py` hosts a repository for other CactOS machines. It always
terminates TLS itself (cactpkg refuses plain `http://`) and can accept newly
built artifacts:

```sh
# local smoke test, with a throwaway certificate
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/key.pem \
    -out /tmp/cert.pem -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
printf '%s\n' "$(head -c24 /dev/urandom | base64)" > /tmp/pkg.token
tools/pkgserver.py --repo repo --host 127.0.0.1 --port 8443 \
    --cert /tmp/cert.pem --key /tmp/key.pem --publish-token-file /tmp/pkg.token
```

- `GET /` lists the packages; `GET /index` and `GET /<file>.cpkg` are what
  `cactpkg` fetches.
- `PUT /publish/<file>.cpkg` (the body is the raw `.cpkg`) stores an artifact
  and rebuilds the index. It needs a bearer token:

  ```sh
  curl -T build-meson/hello-2.0.0.cpkg -H "Authorization: Bearer $TOKEN" \
      https://pkg.example.org/publish/hello-2.0.0.cpkg
  ```

- Publishing is off unless a token is configured (`--publish-token-file`, or
  `$CACTPKG_PUBLISH_TOKEN`), and an artifact is never overwritten unless
  `--allow-overwrite` is given.
- `SIGHUP` (re)loads the certificate: it brings HTTPS up after the first
  issuance and reloads it on every renewal, with no restart.

On a CactOS machine the repository is then just another `repo` entry:

```
# /etc/cactpkg.conf
repo=https://pkg.example.org
```

Run `tools/pkgserver-selftest.sh` to exercise the server locally.

### Certificates with Let's Encrypt

The server answers HTTP-01 challenges itself, so the certificate can be issued
and renewed while the package service keeps running — and it can start *before*
the certificate exists: with no certificate it serves the ACME challenge on
port 80 only, and the first `SIGHUP` brings HTTPS up. Before the first run the
domain needs an **A record pointing at this host**, and port 80 must be
reachable from the internet.

On Artix Linux (dinit) the install is scripted and idempotent:

```sh
sudo tools/pkgserver-deploy.sh --domain pkg.example.org --email you@example.org
```

It installs `pkgserver.py` and a stable repository directory, keeps or creates
the publish token, writes and enables the dinit service, starts it, and — once
the domain resolves — issues the certificate through the server's own ACME
listener. Re-run it after adding the A record; the deploy hook reloads the
certificate on every renewal, with no restart.

The same steps by hand:

```sh
sudo pacman -Syu --needed certbot                    # certbot lives in 'galaxy'; -Syu avoids a partial upgrade
sudo install -m755 tools/pkgserver.py /usr/local/bin/pkgserver.py
sudo install -Dm644 tools/pkgserver.dinit /etc/dinit.d/pkgserver   # edit paths first
sudo mkdir -p /srv/cactpkg/repo /var/www/acme /etc/cactpkg
sudo sh -c 'umask 077; head -c24 /dev/urandom | base64 > /etc/cactpkg/publish.token'
sudo dinitctl enable pkgserver
sudo certbot certonly --webroot -w /var/www/acme -d pkg.example.org \
    --deploy-hook 'dinitctl signal HUP pkgserver'
```

The service description (`tools/pkgserver.dinit`) is:

```ini
type            = process
command         = /usr/local/bin/pkgserver.py --repo /srv/cactpkg/repo ...
smooth-recovery = true
depends-on      = network.target
```

On a systemd host the equivalent is an `ExecStart=` with the same arguments and
`ExecReload=/bin/kill -HUP $MAINPID`. Ports 80 and 443 need root (or
`CAP_NET_BIND_SERVICE`). No client-side change is needed for a public
certificate: a CactOS image trusts the host's CA bundle (Let's Encrypt included)
as-is.

`--repo` can point at the image build's repository, but the build's `stage` step
recreates `LocalRepoCactOS-*/lib/cactpkg/repo` wholesale, so a stable directory
such as `/srv/cactpkg/repo` is the safer publish target.

## Layout

```
CactPkg-x86_64/
├── meson.build
├── docs/FORMAT.md      # formats: directory-package, .cpkg v1, index, db
├── include/cactpkg.h
├── src/                # the manager (C, CactOS ELF)
│   ├── main.c          # CLI
│   ├── util.c          # files, paths, mkdir -p
│   ├── config.c        # /etc/cactpkg.conf + defaults
│   ├── manifest.c      # manifest parser
│   ├── cpkg_io.c       # .cpkg v1 reader
│   ├── repo.c          # repository index (local dir or remote URL)
│   ├── net.c           # HTTP(S) GET for remote repositories
│   ├── db.c            # installed-packages database
│   └── cmd_*.c         # install / remove / query
├── tools/cpkg.py       # host-side tool (build/index/sysrepo/extract/check/dump)
├── tools/pkgserver.py  # HTTPS repository server (serve + publish)
├── tools/pkgserver-selftest.sh  # localhost self-test for the server
├── tools/pkgserver-deploy.sh    # install + start on Artix/dinit (idempotent)
├── tools/pkgserver.dinit        # dinit service description (Artix)
├── examples/hello.c    # demo application for the first package
├── pkg/                # the personal package set (directory packages)
│   ├── hello/          #   demo package
│   ├── cactpkg/        #   the manager itself as a package (bootstrap)
│   └── cact-headers/   #   libc headers (payload filled from CactLibc include/)
├── repo/               # generated: the personal offline repository
└── link.ld
```

## Adding a package to the personal set

1. Create a `pkg/<name>/` directory with a `manifest` (name, version, arch,
   depends, ...) and a `payload/` that mirrors the installation root.
2. `ninja -C build-meson repo` - builds the `.cpkg` and regenerates `index`.
3. `ninja -C build-meson stage` - and the package rides into the image under
   `/usr/lib/cactpkg/repo`.

## License

GPLv3 - see `LICENSE`.
