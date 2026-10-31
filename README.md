NaleHut — VM Panel
==================

NaleHut is an interactive Linux server admin interface with a
virtualization-focused workflow. It is easy to use and very lightweight,
and interacts directly with the operating system from a real Linux
session in your browser.

NaleHut makes Linux discoverable, allowing sysadmins to easily perform
tasks such as managing storage, network configuration, inspecting logs,
starting services and so on.

You can also easily add other machines that are reachable via SSH and
jump between these hosts.

## Highlights

- **Overview dashboard** — CPU, memory, disk and network usage at a glance,
  with system health and recent login information.
- **Services, logs and terminals** — full systemd control from the browser.
- **Storage and networking** — mount, format, RAID; bonds, bridges, firewalld.
- **Multi-host** — connect to further SSH machines and manage them from
  the same session.
- **Light and dark themes** with the NaleHut teal design language.

## Installation

Build and install from source:

```sh
./autogen.sh --prefix=/usr
make
sudo make install
sudo systemctl enable --now cockpit.socket
```

Then open `https://localhost:9090` in your browser.

See [HACKING.md](./HACKING.md) for the development environment, build
dependencies and running tests.

> To create and manage virtual machines (including Windows guests) with
> NaleHut, install the `cockpit-machines` package on the server and enable
> `libvirtd`; the **Virtual Machines** page then appears in the sidebar.

## Security

Please report security issues to the NaleHut maintainers.

## Licenses

* [LGPL-2.1 or later](./LICENSES/LGPL-2.1.txt)
* [GPL-3.0 or later](./LICENSES/GPL-3.0.txt)
* [BSD-3](./LICENSES/BSD-3-Clause.txt)
* [CC-BY-SA-3.0](./LICENSES/CC-BY-SA-3.0.txt)
* [MIT](./LICENSES/MIT.txt)
