# Contributing to Modem Doctor

Thank you for considering contributing to Modem Doctor! This project fixes bufferbloat and connectivity issues on OpenWrt routers with cellular modems.

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b my-feature`
4. Make your changes
5. Test on a real router (see below)
6. Commit and push: `git push origin my-feature`
7. Open a Pull Request

## Development Setup

You need:
- An OpenWrt router with a Quectel modem (tested with EM060K-GL; other models should work)
- SSH access to the router
- A local development machine

### Deploy to router for testing

```sh
# Edit deploy.sh to set your router IP if not 192.168.8.1
./deploy.sh root@192.168.8.1
```

### Build .ipk packages locally

```sh
./create-ipk.sh
# Output in dist/
```

## Code Style

- **Shell scripts**: POSIX sh compatible (BusyBox ash), tabs for indentation
- **JavaScript**: LuCI JS conventions, tabs for indentation
- **JSON**: Tabs for indentation
- See `.editorconfig` for details

### Shell Script Guidelines

- Use `#!/bin/sh` (not bash) — OpenWrt uses BusyBox ash
- No bashisms: no `[[ ]]`, no `${var//pat/rep}` with regex, no arrays
- Use `local` for function variables
- Quote all variable expansions: `"$var"` not `$var`
- Use `logger` for logging, never `echo` to stdout from daemons

## Testing

Before submitting a PR, please test on a real router:

1. Deploy your changes: `./deploy.sh`
2. Check the service starts: `/etc/init.d/modem-doctor start`
3. Verify logs: `logread | grep modem-doctor`
4. Check the LuCI UI loads: Services > Modem Doctor
5. Verify rpcd: `ubus call luci.modem-doctor get_status`

## Reporting Bugs

Please include:
- Router model and OpenWrt version
- Modem model (from `ATI` command or LuCI status page)
- Relevant log output: `logread | grep modem-doctor`
- Steps to reproduce

## Adding Modem Support

If you have a Quectel modem that isn't well supported:

1. Check the AT command responses on your modem:
   ```sh
   # On the router:
   /usr/lib/modem-doctor/modem-doctor-lib.sh detect
   /usr/lib/modem-doctor/modem-doctor-lib.sh signal
   /usr/lib/modem-doctor/modem-doctor-lib.sh temp
   ```
2. If parsing fails, check the raw AT output and open an issue with the output

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
