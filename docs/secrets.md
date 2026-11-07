# Secrets with SecretSpec

eza keeps credentials out of its config files. [SecretSpec](https://secretspec.dev)
is a declarative layer over secret providers:

- [`secretspec.toml`](../secretspec.toml) **declares** the secrets eza may
  use (names, optionality, per-profile providers). It never contains values and
  is safe to commit.
- A **provider** (env, keyring, systemd credentials, ...) supplies the values
  at run time.
- `secretspec run -- <command>` injects the resolved values into the child
  environment; the server itself just reads its normal environment variables.

The deployment binary is **eza-bookmarks**; in production the NixOS module
wraps it in `secretspec run --provider systemd-credential --profile production`.

## The manifest

Two optional secrets, both only needed for AI-assisted tagging:

| Secret | Used by | Required |
|---|---|---|
| `ANTHROPIC_API_KEY` | Anthropic LLM tagging | no |
| `OPENAI_API_KEY` | OpenAI / OpenAI-compatible tagging | no |

Profiles:

| Profile | Providers | Used by |
|---|---|---|
| `default` | provider chosen by the caller | generic `secretspec` use |
| `development` | env (see `devenv.yaml`) with empty defaults | `devenv shell` |
| `production` | `systemd-credential`, then `env` | NixOS module, Docker/K8s wrappers |

Because every secret is optional, **eza runs fine with no secrets at all**:
the AI features are simply disabled. `secretspec check` reports
`missing_optional` and exits 0.

## Development (devenv shell, env provider)

`devenv.yaml` configures SecretSpec with the `env` provider and the
`development` profile, and `devenv.nix` exports the resolved values into the
dev shell (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`; empty when unset). So the
usual workflow is:

```bash
devenv shell

# export keys in your shell (or put them in the gitignored .env file that
# devenv loads) before entering the shell:
export ANTHROPIC_API_KEY="$(pass show anthropic/eza)"

# inspect what the manifest resolves without printing values:
secretspec check -f secretspec.toml -P development

# run an eza command with the resolved secrets injected:
secretspec run -f secretspec.toml -P development -- cabal run eza-bookmarks -- serve
```

Prefer an OS keyring over environment variables? Add the value to the keyring
and switch the provider:

```bash
secretspec set -p keyring -P development ANTHROPIC_API_KEY
# devenv.yaml: secretspec.provider: keyring
```

The manifest's `development` profile declares `default = ""`, so a fresh shell
without any provider still works.

## CI (env provider)

CI injects the keys as environment variables from the CI secret store; no
interactive prompts:

```bash
export SECRETSPEC_PROVIDER=env
export SECRETSPEC_PROFILE=production

# fail if a *required* secret is missing (optional ones are fine):
secretspec check -f secretspec.toml -P production --no-prompt --json

# build/run with secrets injected:
secretspec run -f secretspec.toml -P production -- cabal build all
```

GitHub Actions example:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      SECRETSPEC_PROVIDER: env
      SECRETSPEC_PROFILE: production
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    steps:
      - uses: actions/checkout@v4
      - run: nix profile install nixpkgs#secretspec
      - run: secretspec check -f secretspec.toml --no-prompt --json
      - run: secretspec run -f secretspec.toml -- nix build .#eza-bookmarks
```

## Production on NixOS (systemd-credential provider)

The module's ExecStart is:

    secretspec run --file <manifest> --provider systemd-credential \
      --profile production -- <package>/bin/eza-bookmarks serve

The keys are passed to the unit as **systemd credentials**, which systemd
stores in a private tmpfs (`$CREDENTIALS_DIRECTORY`, mode 0500, readable only
by the service user). They are not in the Nix store, the environment of init,
or the unit file.

```nix
{ config, ... }:
{
  services.eza = {
    enable = true;
    # Absolute paths readable by root; agenix / sops-nix paths work well.
    anthropicApiKeyFile = config.age.secrets.eza-anthropic-api-key.path;
    openaiApiKeyFile = config.age.secrets.eza-openai-api-key.path;
  };

  # Example agenix declaration (values encrypted in the repo):
  age.secrets.eza-anthropic-api-key = {
    file = ./secrets/eza-anthropic-api-key.age;
    owner = "root";
    mode = "0400";
  };
}
```

The module turns each option into
`LoadCredential=ANTHROPIC_API_KEY:<path>` / `LoadCredential=OPENAI_API_KEY:<path>`,
and SecretSpec resolves those credential files by name. The credential name
must match the manifest key exactly.

### Writing the secret files

- **No trailing newline.** `LoadCredential` copies the file byte-for-byte and
  SecretSpec passes the value through verbatim; a trailing `\n` ends up in
  the API key and breaks requests. Use `printf %s "$KEY" > file`, not
  `echo`.
- Root-owned, mode 0400 (or 0440 with a dedicated group) is enough; the file is
  only read by systemd as root at unit start.
- Only set the options for keys you actually have. If both are `null`, the
  wrapper gives SecretSpec an empty private credential directory, every secret
  resolves to "unset", and the AI features are disabled — the unit still
  starts.

### Verify

```bash
# 1. The unit is running and healthy:
systemctl status eza.service
curl -fsS http://127.0.0.1:8080/healthz

# 2. Value-free resolution report inside a transient unit that sees the same
#    credentials (run from the repo checkout; adjust the secretspec binary path
#    if it is not on root's PATH):
sudo systemd-run --unit=eza-secretspec-check --pty --uid=eza \
  --property=LoadCredential=ANTHROPIC_API_KEY:/run/agenix/eza-anthropic-api-key \
  --property=ProtectSystem=strict --property=ProtectHome=yes \
  --working-directory=/tmp \
  "$(command -v secretspec)" check -f "$PWD/secretspec.toml" \
  -p systemd-credential -P production --no-prompt --json
```

The report lists each secret's `status` (`resolved` / `missing_optional`)
without printing values.

### Rotate a key

```bash
# update the credential file (no trailing newline!)
printf %s "$NEW_KEY" | sudo tee /run/agenix/eza-anthropic-api-key >/dev/null
sudo systemctl restart eza.service   # credentials are loaded at unit start
```

### Non-secret environment

Use `services.eza.environmentFile = "/run/secrets/eza.env"` for ordinary
settings (log level, etc.). Do not put secrets there: values in an
EnvironmentFile are visible in the unit environment, unlike systemd
credentials.

## Production with Docker / Kubernetes (env provider)

The image ships `/etc/eza/secretspec.toml` and `secretspec`; run the server
through the env provider instead of the systemd one:

```
/bin/secretspec run --file /etc/eza/secretspec.toml \
  --provider env --profile production -- /bin/eza-bookmarks serve
```

- **Docker Compose**: put the keys in the compose environment / `env_file`;
  see `deploy/docker-compose.yml` for a commented `command:` block.
- **Kubernetes**: the Deployment already uses this command and reads the keys
  from the `eza-secrets` Secret via `envFrom`; see
  [deployment-k8s.md](deployment-k8s.md).

Environment variables are more exposed than systemd credentials (visible in
`/proc/<pid>/environ`, `docker inspect`, pod specs). Prefer Docker secrets /
K8s Secrets over plain environment where your threat model requires it, and
keep the pod spec free of literal values.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Provider backend '...' not found` | Typo in `--provider`; use `env`, `keyring` or `systemd-credential`. |
| `CREDENTIALS_DIRECTORY is not set` | Running `-p systemd-credential` outside a unit with `LoadCredential`. The NixOS module's wrapper handles this; for manual checks use `systemd-run` as above. |
| AI tagging returns 401 | Key has a trailing newline or is stale; re-write with `printf %s` and restart the service. |
| `check` exits non-zero | A *required* secret is missing (none are required in eza's manifest) — inspect the JSON report. |
| Secrets not injected into the server | The wrapper passes the environment only to the child; check the unit's ExecStart still starts with `secretspec run`. |
