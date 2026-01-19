# SuiteCRM on OpenShift

<a href="https://suitecrm.com">
<img width="180px" height="41px" src="https://suitecrm.com/wp-content/uploads/2017/12/logo.png" align="right" />
</a>

Deploy [SuiteCRM 8](https://suitecrm.com/) on Red Hat OpenShift with automatic installation, MariaDB, and Redis.

## Features

- **Automated Installation** - No manual setup wizard required; deploys ready to use
- **OpenShift Optimized** - Runs as non-root, compatible with restricted SCC
- **Persistent Storage** - Database, uploads, and configuration survive restarts
- **Production Ready** - Includes MariaDB database, Redis caching, and scheduled tasks
- **Secure by Default** - TLS-enabled routes, generated credentials, security headers

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

- OpenShift 4.x cluster (or Red Hat Developer Sandbox)
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
│              nginx + PHP-FPM 8.3                         │
│                  (Port 8080)                             │
└──────────┬─────────────────────────────┬────────────────┘
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
| SuiteCRM | `quay.io/ryan_nix/suitecrm-openshift:8.9.2` | CRM application |
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

## Building the Container Image

To build your own image:

```bash
# Build for OpenShift (linux/amd64)
podman build --platform linux/amd64 -t quay.io/your-username/suitecrm-openshift:8.9.2 -f Containerfile .

# Push to registry
podman push quay.io/your-username/suitecrm-openshift:8.9.2
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

## Troubleshooting

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
- [SuiteCRM 8 Installation Guide](https://docs.suitecrm.com/8.x/admin/installation-guide/)
- [OpenShift Documentation](https://docs.openshift.com/)
