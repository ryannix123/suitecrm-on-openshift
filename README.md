# SuiteCRM on OpenShift
[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![SuiteCRM](https://img.shields.io/badge/SuiteCRM-8.10-blue?logo=salesforce)](https://suitecrm.com)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
[![MariaDB](https://img.shields.io/badge/MariaDB-11-blue?logo=mariadb)](https://mariadb.org)
[![PHP](https://img.shields.io/badge/PHP-8.4-777BB4?logo=php&logoColor=white)](https://www.php.net)
[![CentOS](https://img.shields.io/badge/CentOS-Stream%209-purple?logo=centos&logoColor=white)](https://www.centos.org)
[![Quay.io](https://img.shields.io/badge/Quay.io-Container-red?logo=redhat&logoColor=white)](https://quay.io)
[![Build and Push Container Image](https://github.com/ryannix123/suitecrm-on-openshift/actions/workflows/build.yml/badge.svg)](https://github.com/ryannix123/suitecrm-on-openshift/actions/workflows/build.yml)

<a href="https://suitecrm.com">
<img width="180px" height="41px" src="https://suitecrm.com/wp-content/uploads/2017/12/logo.png" align="right" />
</a>

Deploy [SuiteCRM 8](https://suitecrm.com/) on Red Hat OpenShift with automatic installation, MariaDB, and Redis.

## Features

- **Automated Installation** — No manual setup wizard; deploys ready to use via the [CLI installer](https://docs.suitecrm.com/8.x/admin/installation-guide/running-the-cli-installer/)
- **OpenShift Optimized** — Runs as non-root, compatible with restricted SCC
- **Persistent Storage** — Database, uploads, and configuration survive restarts
- **Production Ready** — Includes MariaDB database, Redis caching, and scheduled tasks
- **Secure by Default** — TLS-enabled routes, generated credentials, security headers
- **Weekly CI/CD Builds** — Automated container builds with new SuiteCRM version detection

## Quick Start

```bash
# Clone the repository
git clone https://github.com/ryannix123/suitecrm-on-openshift.git
cd suitecrm-on-openshift

# Deploy to your current OpenShift project
./deploy-suitecrm.sh
```

The script will output the admin credentials and URL when complete. Credentials are also saved to `suitecrm-credentials.txt`.

## Requirements

- OpenShift 4.x cluster (or [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox))
- `oc` CLI logged into your cluster
- Sufficient quota for 3 pods and ~31Gi storage

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    OpenShift Route                       │
│               (TLS termination, edge)                    │
└─────────────────────────┬───────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                   SuiteCRM Pod                           │
│              nginx + PHP-FPM 8.4                         │
│                  (Port 8080)                             │
└──────────┬─────────────────────────────────┬────────────┘
           │                             │
           ▼                             ▼
┌──────────────────────┐    ┌──────────────────────┐
│    MariaDB Pod       │    │     Redis Pod        │
│    (Port 3306)       │    │    (Port 6379)       │
│    10Gi PVC          │    │     1Gi PVC          │
└──────────────────────┘    └──────────────────────┘
```

## Components

| Component | Image | Purpose |
|-----------|-------|---------|
| SuiteCRM | `quay.io/ryan_nix/suitecrm-openshift:8.10.1` | CRM application (PHP 8.4) |
| MariaDB | `quay.io/fedora/mariadb-118` | Database |
| Redis | `docker.io/redis:8-alpine` | Session/cache store |
| Scheduler | CronJob (same image) | Background tasks |

## Usage

### Deploy

```bash
./deploy-suitecrm.sh
```

### Check Status

```bash
./deploy-suitecrm.sh status
```

### View Logs

```bash
# Application logs
oc logs -f deployment/suitecrm

# Database logs
oc logs -f deployment/mariadb
```

### Cleanup

```bash
./deploy-suitecrm.sh cleanup
```

## Configuration

### Environment Variables

The SuiteCRM container accepts these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `mariadb` | Database hostname |
| `DB_PORT` | `3306` | Database port |
| `DB_NAME` | `suitecrm` | Database name |
| `DB_USER` | `suitecrm` | Database username |
| `DB_PASSWORD` | (generated) | Database password |
| `SITE_URL` | (from route) | Public URL |
| `ADMIN_USER` | `admin` | Admin username |
| `ADMIN_PASSWORD` | (generated) | Admin password |

### Storage

| PVC | Size | Purpose |
|-----|------|---------|
| `mariadb-data` | 10Gi | Database files |
| `suitecrm-data` | 20Gi | Uploads, cache, config, customizations |
| `redis-data` | 1Gi | Redis persistence |

## CI/CD

A GitHub Actions workflow (`.github/workflows/build.yml`) automates container image builds:

- **Weekly builds** every Monday at 6:00 AM UTC
- **Auto-detects** new SuiteCRM releases via the GitHub API
- **Multi-tag push** to Quay.io: version (`8.10.1`), major.minor (`8.10`), and `latest`
- **Auto-commits** version bumps back to the repository
- **Manual trigger** with optional version override via `workflow_dispatch`

### Setup

Add two repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `QUAY_USERNAME` | Your Quay.io username |
| `QUAY_PASSWORD` | Your Quay.io encrypted password or [robot account token](https://docs.quay.io/glossary/robot-accounts.html) |

## Customizations

### What's supported out of the box

This deployment is optimized for **fresh installs, demos, and dev environments**. The following are persisted across restarts via PVC:

| Directory | Persisted | Notes |
|-----------|-----------|-------|
| `public/legacy/upload` | ✅ | User uploads, documents |
| `public/legacy/custom` | ✅ | Studio customizations, views, layouts |
| `public/legacy/cache` | ✅ | Application cache |
| `config.php`, `config_override.php` | ✅ | Configuration files |

### What requires a custom image build

SuiteCRM's architecture expects to write to the filesystem at runtime — installing extensions, Module Builder output, composer updates, front-end rebuilds. Containers are designed to be immutable. **These philosophies clash.**

The following are **not persisted** and require building a custom image:

| Directory | Notes |
|-----------|-------|
| `/extensions` | SuiteCRM 8 extensions |
| `public/legacy/modules` (custom) | Module Builder output |
| `/vendor` | Composer dependencies |
| Front-end build | Angular app (for extensions with UI components) |

### Building a custom image with extensions

For production deployments with extensions or custom modules:

1. **Fork this repository**

2. **Add your extensions** to the build context:
   ```
   extensions/
   └── your-extension/
       ├── manifest.yml
       └── ...
   ```

3. **Add custom modules** (if using Module Builder):
   ```
   custom-modules/
   └── YourModule/
       └── ...
   ```

4. **Update the Containerfile** to copy and build:
   ```dockerfile
   # Copy extensions
   COPY extensions/ /var/www/html/extensions/
   
   # Copy custom legacy modules
   COPY custom-modules/ /var/www/html/public/legacy/modules/
   
   # Install composer dependencies (if extensions require them)
   RUN cd /var/www/html && composer install --no-dev --optimize-autoloader
   
   # Rebuild front-end (if extensions have Angular components)
   RUN cd /var/www/html && yarn install && yarn build
   ```

5. **Build and push your image**:
   ```bash
   podman build --platform linux/amd64 -t quay.io/your-username/suitecrm-custom:8.10.1 .
   podman push quay.io/your-username/suitecrm-custom:8.10.1
   ```

6. **Update `deploy-suitecrm.sh`** to use your image:
   ```bash
   SUITECRM_IMAGE="quay.io/your-username/suitecrm-custom:8.10.1"
   ```

### Why this approach?

- **Reproducibility** — Every deployment is identical, built from the same image
- **CI/CD friendly** — Automate builds via GitHub Actions, Tekton, etc.
- **Rollback capability** — Tag images by version, roll back by changing the tag
- **Security** — No runtime filesystem modifications needed

### Alternative: Mount additional PVCs

For development or if you need runtime flexibility, you can mount additional PVCs for `/extensions` and custom module directories. This is more complex and not recommended for production — you lose reproducibility and risk version drift between deployments.

## Building the Container Image

To build your own image:

```bash
# Build for OpenShift (linux/amd64)
podman build --platform linux/amd64 -t quay.io/your-username/suitecrm-openshift:8.10.1 -f Containerfile .

# Push to registry
podman push quay.io/your-username/suitecrm-openshift:8.10.1
```

Update `SUITECRM_IMAGE` in `deploy-suitecrm.sh` to use your image.

## Files

| File | Description |
|------|-------------|
| `deploy-suitecrm.sh` | Main deployment script |
| `Containerfile` | Container build file |
| `entrypoint.sh` | Container startup script with auto-install |
| `nginx.conf` | nginx main configuration |
| `default.conf` | nginx server block |
| `www.conf` | PHP-FPM pool configuration |
| `99-suitecrm.ini` | PHP settings |
| `supervisord.conf` | Process manager configuration |
| `.github/workflows/build.yml` | CI/CD pipeline for weekly builds |

## Troubleshooting

### Developer Sandbox scaled down my pods

The Developer Sandbox automatically scales deployments to zero after periods of inactivity. To wake everything back up:

```bash
oc scale deployment --all --replicas=1 -n $(oc project -q)
```

Your data is preserved on persistent storage — just wait a minute for the pods to start and the database to become ready.

### Pod won't start

```bash
# Check pod events
oc describe pod -l app=suitecrm

# Check container logs
oc logs deployment/suitecrm --previous
```

### Database connection issues

```bash
# Verify MariaDB is running
oc get pods -l component=database

# Check database logs
oc logs deployment/mariadb
```

### Login not working

```bash
# Verify admin user exists
oc exec deployment/mariadb -- bash -c 'mysql -u suitecrm -p"${MYSQL_PASSWORD}" suitecrm -e "SELECT user_name, status FROM users"'
```

### Check credentials

```bash
cat suitecrm-credentials.txt
```

## Contributing

Pull requests welcome! Please test changes on OpenShift before submitting.

## Resources

- [SuiteCRM Documentation](https://docs.suitecrm.com/)
- [SuiteCRM 8.10 Release Notes](https://docs.suitecrm.com/8.x/admin/releases/8.10/)
- [SuiteCRM 8 Installation Guide](https://docs.suitecrm.com/8.x/admin/installation-guide/)
- [OpenShift Documentation](https://docs.openshift.com/)