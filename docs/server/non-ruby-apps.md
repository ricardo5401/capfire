# Deploying non-Ruby apps

Capfire doesn't care what language your app is written in. The server is
Ruby because it uses Rails, but the apps it deploys only need:

1. A git repository.
2. A `capfire.yml` that tells Capfire **what shell command to run** for each
   action (`deploy`, `restart`, `rollback`, `status`).

The default commands assume Capistrano (`bundle exec cap ...`). Override
them and Capfire transparently deploys Node, Python, Go, PHP, static
sites, Docker images, anything that runs on the host.

## How it works

For every `deploy` / `restart` / `rollback` / `status` request, Capfire:

1. Looks up `$CAPFIRE_APPS_ROOT/<app>/capfire.yml`.
2. Resolves the command template for the requested action, with precedence:
   env-specific → global per-app → default Capistrano.
3. (For `deploy` only) runs git sync and the `pre_deploy` hooks.
4. Spawns the final command under `sh -c` via a PTY, streaming stdout/stderr
   line by line to the SSE client.

The command runs as the `capfire` system user, in the app's working
directory, with a clean bundler env (so a Ruby Capfire server does not
leak gems into a Ruby-on-Rails child app).

## Examples

### Node.js (PM2)

```yaml
# /srv/apps/my-node-api/capfire.yml

git_sync: true      # default; listed for explicitness

pre_deploy:
  - "npm ci --production=false"
  - "npm run build"

commands:
  deploy:   "pm2 reload ecosystem.config.js --env %{env}"
  restart:  "pm2 restart my-node-api"
  status:   "pm2 info my-node-api"
  rollback: "git reset --hard HEAD~1 && pm2 reload ecosystem.config.js --env %{env}"
```

### Python (systemd + gunicorn)

```yaml
pre_deploy:
  - "python3 -m venv .venv"
  - ".venv/bin/pip install --no-cache-dir -r requirements.txt"
  - ".venv/bin/python manage.py migrate --noinput"
  - ".venv/bin/python manage.py collectstatic --noinput"

commands:
  deploy:   "sudo systemctl restart my-django-app"
  restart:  "sudo systemctl restart my-django-app"
  status:   "sudo systemctl is-active my-django-app"
  rollback: "git reset --hard HEAD~1 && sudo systemctl restart my-django-app"
```

The `capfire` user needs a sudoers rule for
`systemctl restart my-django-app` without password.

### Go (static binary + systemd)

```yaml
pre_deploy:
  - "go build -o bin/myservice ./cmd/myservice"
  - "install -m 0755 bin/myservice /usr/local/bin/myservice"

commands:
  deploy:   "sudo systemctl restart myservice"
  restart:  "sudo systemctl restart myservice"
  status:   "systemctl status myservice"
```

### PHP (composer + php-fpm)

```yaml
pre_deploy:
  - "composer install --no-dev --optimize-autoloader"
  - "php artisan migrate --force"
  - "php artisan config:cache"
  - "php artisan route:cache"

commands:
  deploy:   "sudo systemctl reload php8.2-fpm"
  restart:  "sudo systemctl reload php8.2-fpm"
  status:   "sudo systemctl is-active php8.2-fpm"
```

### Static site (rsync to a CDN origin)

```yaml
pre_deploy:
  - "npm ci"
  - "npm run build"

commands:
  deploy:  "rsync -az --delete dist/ /var/www/my-site/"
  restart: "true"
  status:  "stat /var/www/my-site/index.html >/dev/null && echo ok || echo missing"
```

### Docker Compose

```yaml
pre_deploy:
  - "docker compose pull"

commands:
  deploy:   "docker compose up -d --remove-orphans"
  restart:  "docker compose restart"
  rollback: "git reset --hard HEAD~1 && docker compose up -d"
  status:   "docker compose ps"
```

## What you still have to do

Capfire is a thin driver — it does not know how to:

- Install your runtime (Ruby, Node, Python, Go, …).
- Manage OS services (the `capfire` user needs `sudoers` for the specific
  `systemctl` calls your deploy runs).
- Build artifacts on a CI and rsync them to multiple nodes — that's your
  pipeline's job.

See [load balancer](config.md#load-balancer-cloudflare) if your non-Ruby
app runs behind Cloudflare — the drain/restore behavior works the same.
