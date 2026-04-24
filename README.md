# Capfire 🔥

**A deploy orchestrator for Capistrano-based Rails apps.**
HTTP API + JWT auth + Cloudflare Load Balancer integration + Server-Sent Events streaming.

Capfire runs _on_ each deploy node and exposes a small, authenticated HTTP surface that lets CI,
chatops, or a human with `curl` trigger deploys, rollbacks, restarts and status checks — and
watch them happen, line by line, in real time.

---

## Table of Contents

1. [Qué es Capfire](#qué-es-capfire)
2. [Despliegue de Capfire en Producción](#despliegue-de-capfire-en-producción)
3. [Gestión de Tokens (CLI)](#gestión-de-tokens-cli)
4. [Cómo Añadir un Nuevo Repo/App](#cómo-añadir-un-nuevo-repoapp)
5. [Uso de la API](#uso-de-la-api)
6. [Integración con GitHub Actions](#integración-con-github-actions)
7. [Seguridad](#seguridad)
8. [Arquitectura](#arquitectura)
9. [Notas Operacionales](#notas-operacionales)
10. [Desarrollo Local](#desarrollo-local)

---

## Qué es Capfire

Capfire es un **orquestador de deploys** pensado para equipos que usan Capistrano en servidores
propios. En lugar de correr `cap production deploy` desde un laptop (que se puede cortar, no deja
trazas y mantiene el nodo en el LB durante el deploy), Capfire:

- **Autentica** cada petición con JWT firmado y con permisos acotados por app, entorno y comando.
- **Drena el nodo** del Cloudflare Load Balancer antes de desplegar en producción, y lo
  reincorpora al terminar (éxito o error), preservando pesos y health checks.
- **Transmite la salida** de `cap deploy` en tiempo real vía Server-Sent Events -- `curl -N` y
  ves cada línea mientras ocurre.
- **Persiste** cada ejecución en Postgres con app, entorno, rama, estado, código de salida y log
  completo -- auditoria lista.
- **Permite revocar tokens** individualmente sin rotar el secreto global.

### Stack

- Ruby 3.2 / Rails 7.1 (API mode)
- PostgreSQL
- Puma (1 worker, N threads -- SSE en memoria sin forks)
- JWT (`ruby-jwt` gem)
- Faraday para llamadas a la API de Cloudflare
- Thor para el CLI (`bin/capfire`)

---

## Despliegue de Capfire en Producción

### Requisitos

| Componente | Version minima |
|------------|---------------|
| Ruby | 3.2.x |
| Bundler | 2.x |
| PostgreSQL | 14+ |
| Puma | 6.x (incluido en Gemfile) |
| Sistema operativo | Ubuntu 22.04 LTS recomendado |

### Variables de entorno

Copia `.env.example` a `.env` (o usa tu gestor de secretos preferido) y rellena:

```bash
# Rails
SECRET_KEY_BASE=<genera con: bundle exec rails secret>

# Base de datos
DATABASE_URL=postgresql://capfire:PASSWORD@localhost:5432/capfire_production

# JWT
# Secreto con el que se firman todos los tokens.
# Cambiarlo invalida TODOS los tokens emitidos.
JWT_SECRET=<genera con: openssl rand -hex 64>

# Cloudflare Load Balancer
# Token con permisos: Zone:Load Balancers:Edit + Account:Load Balancers:Edit.
# Es lo UNICO global para Cloudflare: pool, account y origin viven per-app en
# cada `capfire.yml`. Ver seccion "Cómo Añadir un Nuevo Repo/App".
CF_API_TOKEN=<tu CF API token>

# Capfire
# URL publica de este nodo (usada en logs y audit trail)
CAPFIRE_HOST=https://deploy-node-1.internal.udocz.com

# Directorio raiz donde viven los repos de las apps (default: /srv/apps)
CAPFIRE_APPS_ROOT=/srv/apps
```

> **Nunca** commitees `.env` al repo. Usa `.gitignore` o un vault (AWS Secrets Manager,
> HashiCorp Vault, etc.).

### Setup inicial paso a paso

```bash
# 1. Clonar el repo de Capfire en el servidor
git clone git@github.com:uDocz/capfire.git /opt/capfire
cd /opt/capfire

# 2. Instalar dependencias
bundle install --deployment --without development test

# 3. Configurar entorno
cp .env.example .env
nano .env   # rellenar todas las variables de arriba

# 4. Crear base de datos y correr migraciones
RAILS_ENV=production bundle exec rails db:create db:migrate

# 5. Generar SECRET_KEY_BASE si no lo tienes
bundle exec rails secret

# 6. Arrancar Puma
RAILS_ENV=production bundle exec puma -C config/puma.rb
```

### Credenciales de las apps para el precompile local

Muchas apps (incluidas udoczcom, udocz_api y udocz-institutions) **precompilan assets
localmente en el cockpit antes de hacer rsync a los servers target**. Eso significa que Rails
bootea en modo `production` DENTRO del server de Capfire, lo cual requiere desencriptar
`config/credentials.yml.enc` -- y eso requiere `config/master.key`.

Por eso, para cada app que hace precompile local, necesitas colocar el `master.key` en el
cockpit **una sola vez durante el setup**:

```bash
# En el server de Capfire, una vez por app:
scp laptop:~/proyectos/udoczcom/config/master.key            /srv/apps/udoczcom/config/master.key
scp laptop:~/proyectos/udocz_api/config/master.key           /srv/apps/udocz_api/config/master.key
scp laptop:~/proyectos/udocz-institutions/config/master.key  /srv/apps/udocz-institutions/config/master.key

# Permisos restrictivos
chmod 600 /srv/apps/*/config/master.key
chown deploy:deploy /srv/apps/*/config/master.key
```

`master.key` esta gitignored, por lo que el `git reset --hard` del auto-sync NO lo borra.
Queda persistente entre deploys.

Alternativa si no queres colocar el archivo: exportar `SECRET_KEY_BASE` en el `.env` de Capfire.
Pero el archivo es mas robusto porque las apps a veces leen otras credenciales (API keys,
secret tokens) que estan en `credentials.yml.enc` y requieren la `master.key` para leerse.

### Ejemplo de unidad systemd

```ini
# /etc/systemd/system/capfire.service
[Unit]
Description=Capfire Deploy Orchestrator
After=network.target postgresql.service

[Service]
Type=simple
User=deploy
WorkingDirectory=/opt/capfire
EnvironmentFile=/opt/capfire/.env
ExecStart=/usr/local/bin/bundle exec puma -C config/puma.rb -e production
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Nginx (proxy inverso + SSE)

```nginx
location /capfire/ {
    proxy_pass         http://127.0.0.1:3000/;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;

    # OBLIGATORIO para SSE -- desactiva el buffer de respuesta
    proxy_buffering    off;
    proxy_cache        off;
    chunked_transfer_encoding on;
}
```

> Capfire envia `X-Accel-Buffering: no` en todas las respuestas SSE, pero algunos setups de
> nginx lo ignoran: asegurate de poner `proxy_buffering off` explicitamente.

---

## Gestión de Tokens (CLI)

El CLI carga el entorno Rails completo (misma DB y secreto que el servidor). Siempre correlo
**en el servidor**, en el directorio de Capfire:

```bash
cd /opt/capfire
RAILS_ENV=production bundle exec bin/capfire <comando>
```

### Crear tokens

#### Token de administracion total

```bash
bin/capfire token:create \
  --name=admin \
  --apps='*' \
  --envs=staging,production \
  --cmds=deploy,restart,rollback,status
```

Guarda el JWT que se imprime. Capfire **no lo volvera a mostrar**.

#### Token restringido para GitHub Actions

```bash
bin/capfire token:create \
  --name=github-actions \
  --apps=udoczcom \
  --envs=staging \
  --cmds=deploy
```

#### Token con expiracion

```bash
bin/capfire token:create \
  --name=one-shot \
  --apps=udoczcom \
  --envs=staging \
  --cmds=deploy \
  --expires-in=24h
```

Unidades soportadas en `--expires-in`: `s`, `m`, `h`, `d`.

### Listar tokens

```bash
bin/capfire token:list
```

Muestra id, nombre, jti, claims y estado (`active` / `REVOKED`).

### Revocar un token

```bash
bin/capfire token:revoke 3                        # por id
bin/capfire token:revoke a7b3c0f2-...-...         # por jti
bin/capfire token:revoke 3 --reason="leaked in slack"
```

La revocacion es doble: marca `api_tokens.revoked_at` e inserta en `revoked_tokens`, por lo
que el siguiente decode falla inmediatamente.

### Estructura de claims JWT

Cada token lleva estos claims en su payload:

```json
{
  "sub":  "github-actions",
  "jti":  "a7b3c0f2-1234-5678-abcd-ef0123456789",
  "apps": ["udoczcom"],
  "envs": ["staging"],
  "cmds": ["deploy"],
  "iat":  1745432400,
  "exp":  null
}
```

| Claim | Significado | Wildcard |
|-------|-------------|---------|
| `sub` | Nombre legible del token | -- |
| `jti` | UUID unico; usado para revocar | -- |
| `apps` | Apps que puede tocar | `["*"]` = todas |
| `envs` | Entornos permitidos | solo valores explicitos |
| `cmds` | Comandos permitidos | solo valores explicitos |
| `iat` | Unix timestamp de emision | -- |
| `exp` | Unix timestamp de expiracion (null = sin limite) | -- |

Para decodificar un token manualmente (sin verificar firma):

```bash
echo "<token>" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

---

## Cómo Añadir un Nuevo Repo/App

### 1. Preparar el directorio en el servidor

Capfire ejecuta `bundle exec cap <env> deploy BRANCH=<branch>` dentro del directorio de cada app.
Por defecto busca en `$CAPFIRE_APPS_ROOT/<slug-de-app>` (default: `/srv/apps/<app>`).

```bash
# En el servidor de deploy
sudo mkdir -p /srv/apps/udocz_bot
sudo chown deploy:deploy /srv/apps/udocz_bot
```

### 2. Estructura de directorios esperada

```
/srv/apps/udocz_bot/
+-- Capfile
+-- Gemfile          # solo Capistrano + plugins
+-- Gemfile.lock
+-- config/
    +-- deploy.rb    # configuracion base (repo, usuario, shared_path...)
    +-- deploy/
        +-- staging.rb
        +-- production.rb
```

> El codigo fuente de la app **no** vive aqui -- Capistrano lo clona en el servidor de
> aplicacion. Este directorio es solo la "cabina de mando" de Capistrano.

### 3. Configurar `config/deploy.rb`

```ruby
# /srv/apps/udocz_bot/config/deploy.rb
lock '~> 3.18'

set :application, 'udocz_bot'
set :repo_url,    'git@github.com:uDocz/udocz_bot.git'
set :branch,      ENV.fetch('BRANCH', 'main')   # OBLIGATORIO para que Capfire pase la rama
set :deploy_to,   '/var/www/udocz_bot'

append :linked_files, '.env'
append :linked_dirs,  'log', 'tmp/pids', 'tmp/cache'
```

```ruby
# /srv/apps/udocz_bot/config/deploy/staging.rb
server 'app-staging.udocz.com', user: 'deploy', roles: %w[app web db]
```

```ruby
# /srv/apps/udocz_bot/config/deploy/production.rb
server 'app-prod.udocz.com', user: 'deploy', roles: %w[app web db]
```

### 4. (Opcional pero recomendado) `capfire.yml`

Si necesitas personalizar comandos, manejar un Load Balancer especifico, o desplegar una app que
no usa Capistrano, agrega un `capfire.yml` en la raiz del cockpit de la app. **Todas las
secciones son opcionales**: si no existe el archivo, Capfire usa los defaults de Capistrano y no
toca ningun Load Balancer.

```yaml
# /srv/apps/udocz_bot/capfire.yml

# Overrides globales de comandos. Placeholders: %{app}, %{env}, %{branch}.
commands:
  deploy:   "bundle exec cap %{env} deploy BRANCH=%{branch}"
  restart:  "bundle exec cap %{env} puma:restart"
  rollback: "bundle exec cap %{env} deploy:rollback"
  status:   "bundle exec cap %{env} deploy:check"

# Configuracion por entorno. Permite diferenciar staging vs production.
environments:
  production:
    load_balancer:
      pool_id:    "3c9c314b8ddf22a48c1d80496242777c"
      account_id: "7fd8c19b6d672b6c7e11b83e5f48096d"   # opcional, pools account-scoped
      origin:     "35.185.55.232"                       # IP de ESTE nodo en el pool
  staging:
    load_balancer:
      enabled: false    # explicito; tambien es el default si falta el bloque

# Opcional: desactivar el git sync automatico (default: true).
# git_sync: false
```

**Git sync automatico.** Antes de correr el comando de `deploy`, Capfire ejecuta en el
`work_dir`:

```
git fetch --prune origin
git checkout <branch>
git reset --hard origin/<branch>
```

Esto garantiza que el cockpit siempre este en el commit exacto que pediste desplegar (importante
cuando la app hace precompile local de assets desde el cockpit, como udoczcom). El sync se salta
para `restart`, `rollback` y `status` porque esos no necesitan codigo fresco. Podes desactivarlo
globalmente por app poniendo `git_sync: false` en el `capfire.yml`.

> Nota para despliegues por tag: `git reset --hard origin/<ref>` asume que `<ref>` es una rama.
> Si necesitas desplegar tags frecuentemente, desactiva `git_sync` y hace el checkout manualmente
> dentro del comando de `deploy`.

**Defaults (aplican cuando `capfire.yml` no existe o no declara un comando):**

```
deploy   -> bundle exec cap %{env} deploy BRANCH=%{branch}
restart  -> bundle exec cap %{env} deploy:restart
rollback -> bundle exec cap %{env} deploy:rollback
status   -> bundle exec cap %{env} deploy:check
```

**Apps en otros lenguajes (no Capistrano):** simplemente define los comandos con lo que tengas:

```yaml
commands:
  deploy:  "./scripts/deploy.sh %{branch}"
  restart: "systemctl restart my-go-service"
  status:  "systemctl status my-go-service"
```

**Reglas para el Load Balancer:**
- Solo Cloudflare por ahora.
- Se drena el origen solo en `deploy` (no en restart/rollback/status).
- El `api_token` viene de `CF_API_TOKEN` (ENV global). Pool y origin son per-app.
- Si el bloque `load_balancer` esta ausente o `enabled: false`, no se toca el LB.
- Cada instancia de Capfire drena unicamente su propio `origin` (por eso es per-nodo).

### 5. (Opcional) Ruta personalizada del cockpit

Si el directorio no sigue la convencion `$CAPFIRE_APPS_ROOT/<app>`, añade al `.env` de Capfire:

```bash
CAPFIRE_APP_DIR_UDOCZ_BOT=/opt/custom/path/udocz_bot
```

La variable es el slug de la app en mayusculas con caracteres no alfanumericos reemplazados por `_`.

### 6. Crear un token para la nueva app

```bash
bin/capfire token:create \
  --name=udocz-bot-ci \
  --apps=udocz_bot \
  --envs=staging,production \
  --cmds=deploy,rollback,status
```

Si vas a usar los endpoints `/lb/drain` y `/lb/restore` directamente (orquestadores externos),
incluye tambien `drain` y `restore` en `--cmds`.

### 7. Verificar con un deploy de prueba

```bash
curl -N -X POST https://deploy-node-1.internal.udocz.com/deploys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udocz_bot","env":"staging","branch":"main"}'
```

---

## Uso de la API

Todos los endpoints requieren `Authorization: Bearer <jwt>` (excepto `/healthz`).

### `POST /deploys` -- Iniciar un deploy

```bash
curl -N -X POST https://$CAPFIRE_HOST/deploys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production","branch":"main"}'
```

> `-N` desactiva el buffer de curl -- necesario para ver el SSE en tiempo real.

**Body**

| Campo | Tipo | Requerido | Default | Notas |
|-------|------|-----------|---------|-------|
| `app` | string | yes | -- | | 
| `env` | string | yes | -- | |
| `branch` | string | no | `"main"` | |
| `skip_lb` | bool | no | `false` | Cuando es `true`, NO drena el Load Balancer. Pensado para orquestadores externos que manejan el drain/restore ellos mismos via `/lb/drain` y `/lb/restore`. |

**Respuesta** (`Content-Type: text/event-stream`)

```
event: info
data: {"deploy_id":42,"app":"udoczcom","env":"production","branch":"main","command":"deploy","message":"starting deploy udoczcom@main -> production"}

event: info
data: {"message":"draining node from Cloudflare LB"}

event: log
data: {"line":"00:00 deploy:starting"}

event: log
data: {"line":"00:01 deploy:updating"}

event: log
data: {"line":"00:45 deploy:finishing"}

event: info
data: {"message":"node restored to Cloudflare LB"}

event: done
data: {"deploy_id":42,"exit_code":0,"status":"success"}
```

**Tipos de evento SSE**

| Evento | Cuando se emite |
|--------|----------------|
| `info` | Eventos del ciclo de vida (inicio, LB drain/restore) |
| `log` | Cada linea de salida de `cap deploy` |
| `error` | Excepcion no controlada |
| `done` | Siempre al final -- comprueba `exit_code` (0 = exito) |

---

### `POST /commands` -- Restart, rollback o status

```bash
# Rollback
curl -N -X POST https://$CAPFIRE_HOST/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production","cmd":"rollback"}'

# Restart
curl -N -X POST https://$CAPFIRE_HOST/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production","cmd":"restart"}'

# Status
curl -N -X POST https://$CAPFIRE_HOST/commands \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production","cmd":"status"}'
```

Valores validos para `cmd`: `restart`, `rollback`, `status`.
La respuesta tiene el mismo formato SSE que `/deploys`.

---

### `GET /deploys/:id` -- Consultar un deploy

```bash
curl https://$CAPFIRE_HOST/deploys/42 \
  -H "Authorization: Bearer $TOKEN"
```

**Respuesta**

```json
{
  "id": 42,
  "app": "udoczcom",
  "env": "production",
  "branch": "main",
  "command": "deploy",
  "status": "success",
  "exit_code": 0,
  "triggered_by": "github-actions",
  "started_at": "2026-04-23T21:15:03Z",
  "finished_at": "2026-04-23T21:16:44Z",
  "duration_seconds": 101,
  "log": "00:00 deploy:starting\n00:01 deploy:updating\n..."
}
```

---

### `POST /lb/drain` y `POST /lb/restore` -- Operaciones directas del LB

Endpoints que SOLO tocan el Load Balancer, sin disparar un deploy. Pensados para orquestadores
(GitHub Actions, scripts CI) que necesitan coordinar el drain/restore entre multiples nodos y
ejecutar los pasos del deploy por fuera -- por ejemplo, precompilar assets centralmente y
distribuir el mismo artefacto a todos los nodos antes de flipear un origen.

```bash
# Drenar este nodo del pool
curl -X POST https://$CAPFIRE_HOST/lb/drain \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production"}'

# ... ejecutar el trabajo fuera de Capfire ...

# Reincorporar el nodo al pool
curl -X POST https://$CAPFIRE_HOST/lb/restore \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"udoczcom","env":"production"}'
```

**Body**

| Campo | Tipo | Requerido | Notas |
|-------|------|-----------|-------|
| `app` | string | yes | Debe tener un bloque `load_balancer` en su `capfire.yml` para este env. |
| `env` | string | yes | |

**Respuesta exitosa (`200 OK`)**

```json
{
  "status": "drained",
  "app": "udoczcom",
  "env": "production",
  "pool_id": "3c9c314b8ddf22a48c1d80496242777c",
  "origin": "35.185.55.232"
}
```

**Errores**

- `422 Unprocessable Entity` -- la app no tiene bloque `load_balancer` para ese env, o el bloque
  esta incompleto (falta `pool_id`, `origin`, o `CF_API_TOKEN`).
- `502 Bad Gateway` -- error contra la API de Cloudflare. El body incluye el mensaje.

**Flujo tipico con un orquestador externo (ej. udoczcom con 2 nodos):**

```bash
# 1. Build centralizado de assets en CI, rsync a ambos nodos con los MISMOS hashes.
rails assets:precompile
rsync public/assets/ deploy@node1:/srv/shared/assets/
rsync public/assets/ deploy@node2:/srv/shared/assets/

# 2. Rolling node-by-node
for node in node1 node2; do
  curl -X POST https://$node/lb/drain    -H "Authorization: Bearer $TOKEN" -d '{"app":"udoczcom","env":"production"}'
  curl -N -X POST https://$node/deploys   -H "Authorization: Bearer $TOKEN" -d '{"app":"udoczcom","env":"production","branch":"main","skip_lb":true}'
  curl -X POST https://$node/lb/restore  -H "Authorization: Bearer $TOKEN" -d '{"app":"udoczcom","env":"production"}'
done
```

El `skip_lb: true` en `/deploys` es clave cuando el orquestador ya se encargo del drain via
`/lb/drain`: evita que Capfire intente drenar por segunda vez (idempotente, pero genera ruido).

---

### `GET /healthz` -- Liveness probe

```bash
curl https://$CAPFIRE_HOST/healthz
# 200 ok
```

No requiere autenticacion. Util para load balancers y monitoreo.

---

## Integración con GitHub Actions

### Workflow completo de ejemplo

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: staging
        type: choice
        options: [staging, production]

jobs:
  deploy:
    name: Deploy to ${{ inputs.environment || 'staging' }}
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment || 'staging' }}
    concurrency:
      group: deploy-${{ inputs.environment || 'staging' }}
      cancel-in-progress: false   # nunca cancelar un deploy en vuelo

    steps:
      - name: Trigger deploy via Capfire
        env:
          CAPFIRE_TOKEN: ${{ secrets.CAPFIRE_TOKEN }}
          CAPFIRE_HOST:  ${{ secrets.CAPFIRE_HOST }}
          TARGET_ENV:    ${{ inputs.environment || 'staging' }}
        run: |
          set -euo pipefail

          echo "Deploying branch ${GITHUB_REF_NAME} -> ${TARGET_ENV}"

          curl -N --fail-with-body \
            -X POST "${CAPFIRE_HOST}/deploys" \
            -H "Authorization: Bearer ${CAPFIRE_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"app\":\"udoczcom\",\"env\":\"${TARGET_ENV}\",\"branch\":\"${GITHUB_REF_NAME}\"}" \
          | tee /tmp/capfire_output.txt

          EXIT_CODE=$(grep '^data:' /tmp/capfire_output.txt \
            | tail -1 \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['exit_code'])" 2>/dev/null || echo 1)

          echo "Deploy finished with exit_code=${EXIT_CODE}"
          exit "${EXIT_CODE}"
```

### Secrets de GitHub requeridos

Configura estos secrets en **Settings > Secrets and variables > Actions**:

| Secret | Descripcion |
|--------|-------------|
| `CAPFIRE_TOKEN` | JWT emitido con `token:create` |
| `CAPFIRE_HOST` | URL base del nodo Capfire (ej. `https://deploy.internal.udocz.com`) |

### Token recomendado para Actions

```bash
# Solo puede hacer deploy de udoczcom en staging
bin/capfire token:create \
  --name=github-actions-staging \
  --apps=udoczcom \
  --envs=staging \
  --cmds=deploy

# Para produccion (workflow separado con environment protection rules)
bin/capfire token:create \
  --name=github-actions-production \
  --apps=udoczcom \
  --envs=production \
  --cmds=deploy,rollback
```

---

## Seguridad

### Por que JWT con claims

Los tokens de Capfire no son strings opacos -- son JWTs con permisos explicitos firmados con
`JWT_SECRET`. Esto permite:

- **Principio de minimo privilegio**: cada caller recibe exactamente los permisos que necesita
  (`apps`, `envs`, `cmds`). Un token de CI para staging no puede tocar produccion aunque lo
  intercepten.
- **Revocacion individual**: comprometer un token no obliga a rotar el secreto global y
  reinvalidar todos los demas tokens. `token:revoke` es suficiente.
- **Audit trail**: cada deploy registra `triggered_by` (el `sub` del JWT) y el `jti`, lo que
  permite rastrear quien hizo que y cuando.
- **Expiracion opcional**: tokens de corta vida (`--expires-in=1h`) para pipelines CI efimeros.

### HTTPS obligatorio

Capfire transmite JWTs y salida de deploys en texto plano sobre HTTP por defecto. En produccion:

- **Siempre** pon un proxy inverso (nginx, Caddy) con TLS delante.
- El token JWT viaja en el header `Authorization` -- sin TLS, cualquiera en la red lo ve.
- Usa certificados validos (Let's Encrypt, ACM, etc.) -- no self-signed en produccion.

### Firewall

Capfire no deberia ser accesible desde internet abierto:

```bash
# Solo permitir acceso desde tu red interna
ufw allow from 10.0.0.0/8 to any port 3000
ufw deny 3000
# Para GitHub Actions considera un tunel o Tailscale
```

### Checklist de seguridad para produccion

- [ ] `JWT_SECRET` generado con `openssl rand -hex 64` (no hardcodeado)
- [ ] `SECRET_KEY_BASE` generado con `bundle exec rails secret`
- [ ] Capfire detras de nginx/Caddy con TLS
- [ ] Puerto 3000 no expuesto a internet
- [ ] `CF_API_TOKEN` con permisos minimos (solo Load Balancers Edit)
- [ ] Tokens de CI con `--envs` y `--apps` restringidos
- [ ] `.env` fuera del repo y con permisos `600`

---

## Arquitectura

```
POST /deploys         +------------------+
  (JWT auth) ------>  | DeploysController|
                      +--------+---------+
                               |
                               v
POST /lb/{action}     +------------------+
  (JWT auth) ------>  |   LbController   |----+
                      +------------------+    |
                                              v
                      +------------------+   +--------------+
                      |   DeployService  |<--|  AppConfig   |  (reads capfire.yml)
                      +--------+---------+   +--------------+
                               |                       |
                 LB enabled?   |                       |
                  per-app yml  v                       v
                      +----------------------+    +------------------+
                      | CloudflareLbService  |    |   CommandRunner  |
                      +----------------------+    +--------+---------+
                                                           | PTY.spawn('sh -c "...")
                                                           v yields lines
                                                  +------------------+
                                                  |    SseWriter     |
                                                  +--------+---------+
                                                           v
                                                    Client (curl -N)
```

- **`DeploysController` / `CommandsController`** -- thin, auth + param validation only.
- **`LbController`** -- standalone `/lb/drain` and `/lb/restore` endpoints for external
  orchestrators that prefer to run the deploy steps themselves.
- **`DeployService`** -- owns the lifecycle (DB record + LB drain/restore + runner + terminal event).
  Decides whether to touch the LB based on `AppConfig#load_balancer_for(env)`; no longer keyed off
  a hardcoded `PRODUCTION_ENVS` list.
- **`AppConfig`** -- reads `capfire.yml` from the app's working directory and exposes
  `command_for(...)` and `load_balancer_for(env)`. Source of truth for "what does deploy mean for
  this app".
- **`CommandRunner`** -- formerly `CapistranoRunner`. Runs whatever shell command `AppConfig`
  returned via `sh -c`. PTY preferred, Open3 fallback. Yields raw log lines.
- **`CloudflareLbService`** -- Faraday + retries; fetches pool, flips `enabled`, puts it back.
  Receives a per-instance `LoadBalancerConfig` (pool/origin/account), not globals.
- **`LoadBalancerConfig`** -- tiny immutable struct built by `AppConfig`. Reads `CF_API_TOKEN`
  from ENV (the only Cloudflare global left).
- **`JwtService`** -- encode/decode + claim-based `authorize!`.
- **`SseWriter`** -- shields the controller from SSE formatting and closed-stream errors.

Puma corre en **1 worker, muchos threads** -- el stream SSE en memoria vive en un solo proceso
(sin forks que partan conexiones). El worker timeout sube a 1h porque los deploys reales tardan.

---

## Base de Datos

Tres tablas, todas en Postgres:

| Tabla | Proposito |
|-------|-----------|
| `deploys` | Una fila por ejecucion: app, env, branch, status, exit_code, log completo |
| `api_tokens` | Metadata de cada token emitido |
| `revoked_tokens` | Lookup rapido de `jti` revocados durante el decode |

Los logs viven en `deploys.log` (TEXT). Si crece demasiado, muevelos a object storage --
`append_log!` es el unico punto de escritura.

---

## Notas Operacionales

- **SSE + nginx**: pon `proxy_buffering off;` en el location block de Capfire. Capfire ya envia
  `X-Accel-Buffering: no` pero algunos setups lo ignoran.
- **Retencion de logs**: sin rotacion automatica. Añade un cron para purgar `deploys` mas
  antiguos de N dias si el disco lo requiere.
- **Deploys concurrentes**: Capfire no bloquea -- dos deploys del mismo app/env correran en
  paralelo. Añade un `before_action` con mutex en `DeploysController` si Capistrano no lo tolera.
- **Reinicios mid-deploy**: si el cliente se desconecta, el deploy sigue corriendo en background.
  Al terminar, la fila en `deploys` refleja el estado final -- consultala con `GET /deploys/:id`.
- **Cloudflare LB con multiples nodos**: cada nodo tiene su propio `CF_NODE_ORIGIN` apuntando
  a su direccion en el pool. Capfire solo toca su propia entrada.

---

## Desarrollo Local

```bash
# 1. Clonar y dependencias
git clone git@github.com:uDocz/capfire.git
cd capfire
bundle install

# 2. Configurar
cp .env.example .env
# Editar .env (puedes dejar CF_* vacios)

# 3. Base de datos
bin/rails db:create db:migrate

# 4. Arrancar
bin/rails server -p 3000

# 5. Emitir un token de prueba
RAILS_ENV=development bin/capfire token:create \
  --name=local-test --apps='*' --envs=staging --cmds=deploy,restart,rollback,status

# 6. Probar
curl -N -X POST http://localhost:3000/deploys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"app":"my-app","env":"staging","branch":"main"}'
```

Tests:

```bash
bundle exec rspec
```

---

## License

Proprietary -- uDocz internal tooling.
