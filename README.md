# mira

Minimal deploy tool for Rails 8+ applications.

mira is inspired by mina, but intentionally tiny and personal-use focused.
It does only three things:

- setup remote folders
- deploy a release from local git branch
- rollback to previous release
- control puma lifecycle

## Requirements

- Ruby 3.1+
- Local: git, ssh
- Remote: bash, tar, bundle, rails

## Quick Start

Use `--verbose` with any command when you want full command/script logs during execution.

```bash
./bin/mira --verbose deploy
```

1. Create config:

```bash
./bin/mira init
```

2. Edit `Mirafile` with your server/app settings.

3. Prepare remote folders:

```bash
./bin/mira setup
```

4. Deploy:

```bash
./bin/mira deploy
```

Or with a specific environment (Mina-style):

```bash
./bin/mira staging deploy
./bin/mira production deploy
```

5. Rollback if needed:

```bash
./bin/mira rollback
```

6. Manual Puma control (optional):

```bash
./bin/mira puma:status
./bin/mira puma:restart
```

## Mirafile example

```ruby
set :host, 'your-server.example.com'
set :user, 'deploy'
set :port, 22
set :deploy_to, '/var/www/myapp'

set :repo_path, '.'
set :branch, 'main'
# set :ruby_version, 'ruby-4.0.2'

set :rails_env, 'production'
set :migrate, true
set :precompile_assets, true
set :puma_restart_on_deploy, true
set :keep_releases, 5
# set :bundle_path, 'vendor/bundle'
# set :bundle_withouts, 'development test'

set :shared_dirs, ['log', 'tmp/pids', 'tmp/cache', 'public/uploads', 'config/credentials']
set :shared_files, ['config/master.key']
# set :upload_shared_files, ['config/master.key', 'config/credentials/production.key']

# Optional Puma settings
# set :puma_state_path, 'tmp/pids/puma.state'
# set :puma_pid_path, 'tmp/pids/puma.pid'
# set :puma_start_command, 'setsid -f env RAILS_ENV=production bundle exec puma -C config/puma.rb --pidfile tmp/pids/puma.pid --state tmp/pids/puma.state >> log/puma.log 2>&1 < /dev/null'

# Optional override: custom app restart command (systemd/supervisor etc.)
# set :restart_command, 'sudo systemctl restart myapp'

# Mina-style environments
environment 'staging' do
	set :deploy_to, '/var/www/myapp-staging'
	set :rails_env, 'staging'
	set :branch, 'develop'
end

environment 'production' do
	set :deploy_to, '/var/www/myapp'
	set :rails_env, 'production'
	set :branch, 'main'
end
```

Then deploy with:

```bash
./bin/mira staging deploy
./bin/mira production deploy
```

## Notes

- Deployment uses `git archive` from your local repository and streams tar over ssh.
- Shared directories are symlinked into each release.
- `bundle_path` (default `vendor/bundle`) is automatically shared across releases, Mina-style.
- `mira deploy` automatically restarts Puma after switching `current`.
- Set `ruby_version` when remote host uses RVM and has multiple Ruby versions.
- This project is intentionally minimal and does not include plugin architecture.

## Rails Credentials

For Rails credentials, run `mira setup` first so shared paths exist, then copy keys to server:

```bash
scp -P 22 config/master.key deploy@your-server.example.com:/var/www/myapp/shared/config/master.key
```

If you already share `config/credentials` as a directory, do not also configure
`config/credentials/production.key` in `shared_files`. The key is already covered by
the shared directory link.

Or enable automatic upload by setting `upload_shared_files`. When configured, `mira setup` will upload those files from local `repo_path` into `shared`.

## Local Rails 8 Smoke Test

- A minimal Rails 8 app is available at `test_apps/rails8_smoke`.
- Its `Mirafile` enables `local_mode`, so you can test deploy flow without SSH server.
- The local smoke app boots Puma on `127.0.0.1:3101` with a test-only `SECRET_KEY_BASE_DUMMY`.
- The smoke script validates deploy, Puma restart, `/up` HTTP health, and rollback.
- Run smoke test:

```bash
chmod +x scripts/smoke_local.sh
scripts/smoke_local.sh
```
