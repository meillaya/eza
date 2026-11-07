# Publishing eza over Tailscale Serve (HTTPS)

eza uses WebAuthn passkeys. Browsers only allow passkey ceremonies on a
**secure origin**: HTTPS (or `http://localhost`). Tailscale Serve gives you
that without opening ports: it terminates TLS with a certificate for your
tailnet DNS name and proxies to eza's loopback listener. The result is
`https://<machine>.<tailnet>.ts.net`, reachable only from your tailnet.

Use **Serve**, not Funnel: Serve stays private to the tailnet, Funnel exposes
the app to the public internet.

## Prerequisites

1. `tailscaled` is running and the machine is logged in (`tailscale status`).
2. **MagicDNS** and **HTTPS certificates** are enabled for the tailnet:
   admin console → DNS → enable MagicDNS and "HTTPS Certificates". Without
   this, Serve cannot obtain the TLS certificate.
3. eza listens on loopback (the module default `bind = "127.0.0.1:8080"`).
4. A recent Tailscale (Serve and its `--bg`/`--https` flags: 1.54+).

## NixOS (module-managed)

```nix
{ ... }:
{
  services.tailscale.enable = true;

  services.eza = {
    enable = true;
    bind = "127.0.0.1:8080";

    # Tailnet DNS name of this machine (no trailing dot):
    #   tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//'
    publicOrigin = "https://eza.tail1234.ts.net";
    rpId = "eza.tail1234.ts.net";

    tailscaleServe.enable = true;
    tailscaleServe.httpsPort = 443;   # 443, 8443 or 10000
  };
}
```

With `tailscaleServe.enable`, the module adds
`systemd.services.eza-tailscale-serve` (runs as root, wants
`tailscaled.service` + `eza.service`), which executes:

    tailscale serve --bg --https=443 http://127.0.0.1:8080

and leaves the Serve configuration in place on stop, so other Serve targets on
the machine are never touched (the Serve config is idempotent and re-applied
on the next start). To retire the mapping deliberately:

```bash
sudo tailscale serve reset          # clears ALL Serve config on this node
# or remove just this mapping in the Tailscale admin console / with the
# `tailscale serve` config commands for your version.
```

The eza unit itself is unchanged and keeps listening on loopback only.

Check the wiring:

```bash
tailscale serve status
systemctl status eza-tailscale-serve.service
curl -fsS https://eza.tail1234.ts.net/healthz
```

## Docker / non-NixOS (manual Serve)

With eza running on `127.0.0.1:8080`:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:8080
tailscale serve status

# environment for eza (docker compose / systemd / .env):
#   PUBLIC_ORIGIN=https://eza.tail1234.ts.net
#   EZA_RP_ID=eza.tail1234.ts.net

# remove the Serve configuration:
sudo tailscale serve reset
```

If port 443 on the tailnet root is already used by another Serve target, use
8443 or 10000:

```bash
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8080
# PUBLIC_ORIGIN=https://eza.tail1234.ts.net:8443
```

The RP ID never includes the port: `eza.tail1234.ts.net`.

## Finding the exact hostname

```bash
tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'
# eza.tail1234.ts.net
```

The JSON value ends with a trailing dot; strip it. `publicOrigin` is
`https://` + that host (plus `:port` if not 443); `rpId` is the bare host.
The server derives `EZA_RP_ID` from `PUBLIC_ORIGIN`'s host when `rpId` is not
set, and turns on Secure cookies automatically for `https://` origins.

## Passkey / RP ID rules (read before enrolling)

- The **RP ID is permanent for a credential**. Passkeys enrolled for
  `eza.tail1234.ts.net` will not work if the machine is renamed, moved to
  another tailnet, or served under a different DNS name: the browser will not
  release them for a different origin.
- Pick a name you can keep: the machine name in the tailnet, a Tailscale
  custom domain, or a real domain via Caddy. Changing it later means
  re-enrolling passkeys. The one-time recovery codes is exactly what the **one-time recovery codes**
  are for.
- The recovery codes are shown **once**, by the first-run setup page. Save them
  in a password manager. If a passkey is lost, a recovery code opens a scoped
  re-enrollment flow; if the passkey *and* the codes are lost, there is no
  in-app way back in.
- Certificates rotate automatically and do not affect credentials; only the
  origin/host matters.
- Do not register the same account against two origins (`http://localhost`
  during testing plus the tailnet name): browsers scope credentials per
  origin. Do local testing on `localhost` and production on the tailnet name.

## Verification from another device

From a phone/laptop on the same tailnet:

```bash
curl -fsS https://eza.tail1234.ts.net/healthz
# {"status":"ok","version":"0.1.0"}
```

Then open the URL in a browser and complete first-run enrollment. A
"not secure" warning or a passkey prompt that never appears means the URL is
not HTTPS or the RP ID does not match the host; fix `publicOrigin`/`rpId`
and restart eza.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `tailscale serve` says HTTPS is not enabled | Enable "HTTPS Certificates" in the tailnet DNS settings. |
| `curl https://...` fails from a tailnet device | Check `tailscale status`, `tailscale serve status`, and that the eza unit is running on 127.0.0.1:8080. |
| `serve` reports the port is in use | Another Serve target owns 443; use `httpsPort = 8443` and include `:8443` in `publicOrigin`. |
| Passkey prompt rejected with "invalid origin" | `publicOrigin` must be exactly the browser URL; `rpId` must be its host without port. |
| Machine renamed, passkeys stopped working | Old RP ID is gone; use the recovery codes to re-enroll, or restore the old machine name. |
| eza-tailscale-serve failed | `journalctl -u eza-tailscale-serve`; usually `tailscaled` not up or the tailnet lacks cert support. |
