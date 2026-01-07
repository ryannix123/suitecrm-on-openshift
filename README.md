# SuiteCRM on OpenShift

Deploy [SuiteCRM](https://suitecrm.com/) - the open-source CRM - on OpenShift with a single command. This project provides a production-ready container image and deployment script optimized for OpenShift's security model.

![SuiteCRM](https://suitecrm.com/wp-content/uploads/2023/04/suitecrm-logo.svg)

## Features

- 🐳 **CentOS Stream 9** base image with nginx + PHP-FPM 8.3
- 🔒 **OpenShift Compatible** - runs as non-root with arbitrary UID support
- 🚀 **One-Command Deployment** - deploys SuiteCRM, MariaDB, and Redis
- 📦 **Redis Caching** - automatic session handling and application cache
- ⏰ **Scheduler Included** - CronJob for SuiteCRM background tasks
- 🔐 **Auto-Generated Credentials** - secure random passwords created at deploy time

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Cluster                        │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                  Your Project/Namespace                 │ │
│  │                                                         │ │
│  │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │ │
│  │   │  SuiteCRM   │──▶│   MariaDB   │   │    Redis    │  │ │
│  │   │  (nginx +   │   │   (10.11)   │   │  (sessions  │  │ │
│  │   │  PHP-FPM)   │──▶│             │   │  + cache)   │  │ │
│  │   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘  │ │
│  │          │                 │                 │         │ │
│  │          ▼                 ▼                 ▼         │ │
│  │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │ │
│  │   │     PVC     │   │     PVC     │   │     PVC     │  │ │
│  │   │  (uploads)  │   │   (data)    │   │  (cache)    │  │ │
│  │   └─────────────┘   └─────────────┘   └─────────────┘  │ │
│  └────────────────────────────────────────────────────────┘ │
│                            │                                 │
│                            ▼                                 │
│                     ┌─────────────┐                         │
│                     │    Route    │                         │
│                     │  (TLS/HTTPS)│                         │
│                     └─────────────┘                         │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
                      🌐 Internet
```

## Quick Start

### Prerequisites

- OpenShift 4.x cluster (or [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) - free!)
- `oc` CLI installed and logged in

### Deploy

```bash
# Clone the repo
git clone https://github.com/ryannix123/suitecrm-on-openshift.git
cd suitecrm-on-openshift

# Login to OpenShift
oc login <your-cluster>

# Switch to your project
oc project <your-project>

# Deploy SuiteCRM
./deploy-suitecrm.sh
```

That's it! The script will:
1. Deploy Redis for session/cache management
2. Deploy MariaDB with persistent storage
3. Deploy SuiteCRM with nginx + PHP-FPM
4. Create a CronJob for scheduled tasks
5. Configure a Route with TLS
6. Save credentials to `suitecrm-credentials.txt`

### Complete Setup

After deployment, navigate to the URL shown in the output (e.g., `https://suitecrm-myproject.apps.cluster.example.com/install.php`) and complete the SuiteCRM installation wizard using the database credentials from `suitecrm-credentials.txt`.

## Commands

```bash
# Deploy SuiteCRM
./deploy-suitecrm.sh

# Check deployment status
./deploy-suitecrm.sh status

# Remove all SuiteCRM resources
./deploy-suitecrm.sh cleanup
```

## Configuration

### Environment Variables

The container supports the following environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `mariadb` | Database hostname |
| `DB_PORT` | `3306` | Database port |
| `DB_NAME` | `suitecrm` | Database name |
| `DB_USER` | `suitecrm` | Database username |
| `DB_PASSWORD` | - | Database password |
| `REDIS_HOST` | `redis` | Redis hostname |
| `REDIS_PORT` | `6379` | Redis port |
| `SITE_URL` | - | Full URL for SuiteCRM |
| `PHP_MEMORY_LIMIT` | `512M` | PHP memory limit |
| `PHP_MAX_EXECUTION_TIME` | `300` | PHP max execution time |
| `PHP_UPLOAD_MAX_FILESIZE` | `100M` | Maximum upload file size |

### Storage

The deployment creates three Persistent Volume Claims:

| PVC | Default Size | Purpose |
|-----|--------------|---------|
| `suitecrm-data` | 20Gi | Uploads, cache, custom modules |
| `mariadb-data` | 10Gi | Database storage |
| `redis-data` | 1Gi | Redis persistence |

Modify the sizes in `deploy-suitecrm.sh` if needed:

```bash
DB_STORAGE_SIZE="10Gi"
SUITECRM_STORAGE_SIZE="20Gi"
REDIS_STORAGE_SIZE="1Gi"
```

## Container Image

The container image is available on Quay.io:

```
quay.io/ryan_nix/suitecrm-openshift:7.15.0
```

### Build Your Own

```bash
# Build the container
podman build -t quay.io/your-org/suitecrm-openshift:7.15.0 -f Containerfile .

# Push to your registry
podman push quay.io/your-org/suitecrm-openshift:7.15.0
```

Then update `SUITECRM_IMAGE` in `deploy-suitecrm.sh`.

### Container Stack

- **Base**: CentOS Stream 9
- **Web Server**: nginx (port 8080)
- **PHP**: 8.3 from Remi repository
- **Process Manager**: supervisord (manages nginx + PHP-FPM)
- **Extensions**: gd, mbstring, xml, zip, curl, intl, bcmath, opcache, mysqlnd, imap, ldap, soap, apcu, redis, sodium

## Red Hat Developer Sandbox

This project works great on the [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) - a free OpenShift environment:

1. Sign up at https://developers.redhat.com/developer-sandbox
2. Login via `oc login` (copy command from web console)
3. Run `./deploy-suitecrm.sh`

Note: The sandbox has resource quotas, but SuiteCRM runs fine within them.

## Troubleshooting

### Check pod status
```bash
oc get pods -l app=suitecrm
```

### View SuiteCRM logs
```bash
oc logs -f deployment/suitecrm
```

### View MariaDB logs
```bash
oc logs -f deployment/mariadb
```

### Access the container shell
```bash
oc rsh deployment/suitecrm
```

### Database connection issues
Ensure MariaDB is running and ready:
```bash
oc get pods -l component=database
oc logs deployment/mariadb
```

## Related Projects

- [Nextcloud on OpenShift](https://github.com/ryannix123/nextcloud-ocp) - Deploy Nextcloud on OpenShift
- [OpenEMR on OpenShift](https://github.com/ryannix123/openemr-openshift) - Deploy OpenEMR on OpenShift

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

SuiteCRM itself is licensed under the [AGPL-3.0 License](https://www.gnu.org/licenses/agpl-3.0.html).

## Acknowledgments

- [SuiteCRM](https://suitecrm.com/) - The open-source CRM
- [Red Hat OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift) - Enterprise Kubernetes platform
- [Remi's RPM Repository](https://rpms.remirepo.net/) - PHP packages for Enterprise Linux
