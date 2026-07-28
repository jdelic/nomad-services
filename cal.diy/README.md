# cal.diy Nomad service

This job runs the open-source cal.diy web app for public scheduling. PostgreSQL
and Redis are expected to exist outside Nomad at `postgresql.local` and
`redis.local`.

## Files

- `cal-diy.nomad`: cal.diy web task and smartstack exposure.

## Public hostnames

The job advertises these smartstack hostnames:

- `schedule.maurus.net` for cal.diy

Override `cal_diy_hostname` at submit time if you want a different subdomain.
DNS can be created out-of-band.

## Images

The cal.diy web task defaults to the official open-source Docker image:

```text
calcom/cal.com:latest
```

## External dependencies

Create a PostgreSQL database and user on `postgresql.local`:

```sql
CREATE USER caldiy WITH PASSWORD '...';
CREATE DATABASE caldiy OWNER caldiy;
```

The job uses Redis through:

```text
redis://redis.local:6379
```

The default Radicale URL is:

```text
https://cal.maurus.net
```

## Nomad variables

Create these Nomad variables before running the job:

```bash
nomad var put nomad/jobs/cal.diy/app \
  nextauth_secret=... \
  calendso_encryption_key=...

nomad var put nomad/jobs/cal.diy/db \
  postgres_password=...
```

cal.diy includes a CalDAV calendar integration. After first-run setup, connect
CalDAV through the cal.diy UI.
