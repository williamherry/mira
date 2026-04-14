# frozen_string_literal: true

require 'shellwords'
require 'open3'

module Mira
  class Deployer
    def initialize(config, io: $stdout, verbose: false)
      @config = config
      @io = io
      @verbose = verbose
    end

    def setup
      log 'Setting up deploy directories on remote host'
      run_remote <<~SH
        set -e
        mkdir -p #{esc(deploy_to)}
        mkdir -p #{esc(releases_path)}
        mkdir -p #{esc(shared_path)}
      SH

      commands = []
      shared_dirs.each do |dir|
        commands << %(mkdir -p #{esc(File.join(shared_path, dir))})
      end

      shared_files.each do |file|
        full_path = File.join(shared_path, file)
        commands << %(mkdir -p #{esc(File.dirname(full_path))})
        commands << %(touch #{esc(full_path)})
      end

      run_remote(commands.join("\n")) unless commands.empty?

      upload_configured_shared_files

      log 'Setup complete'
    end

    def deploy
      release_id = Time.now.utc.strftime('%Y%m%d%H%M%S')
      release_path = File.join(releases_path, release_id)

      log "Creating release #{release_id}"
      upload_source(release_path)

      with_remote_batch do
        link_shared_paths(release_path)
        install_dependencies(release_path)
        migrate_db(release_path) if @config.fetch(:migrate)
        precompile_assets(release_path) if @config.fetch(:precompile_assets)

        log 'Switching current symlink'
        run_remote %(ln -nfs #{esc(release_path)} #{esc(current_path)})

        restart_application
        cleanup_old_releases
      end

      log 'Deploy complete'
    end

    def rollback
      log 'Rolling back to previous release'
      run_remote <<~SH
        set -e
        previous_release=$(ls -1 #{esc(releases_path)} | sort | tail -n 2 | head -n 1)
        if [ -z "$previous_release" ]; then
          echo 'No previous release found'
          exit 1
        fi
        ln -nfs #{esc(releases_path)}/$previous_release #{esc(current_path)}
      SH
      restart_application
      log 'Rollback complete'
    end

    def puma_start
      log 'Starting Puma'
      command = @config.fetch(:puma_start_command)

      if command && !command.empty?
        run_remote <<~SH, ruby: true
          set -e
          cd #{esc(current_path)}
          if [ -f #{esc(puma_pid_path)} ] && kill -0 "$(cat #{esc(puma_pid_path)})" 2>/dev/null; then
            echo 'Puma already running'
            exit 0
          fi
          #{command}
        SH
      else
        run_remote <<~SH, ruby: true
          set -e
          cd #{esc(current_path)}
          if [ -f #{esc(puma_pid_path)} ] && kill -0 "$(cat #{esc(puma_pid_path)})" 2>/dev/null; then
            echo 'Puma already running'
            exit 0
          fi
          mkdir -p #{esc(File.dirname(File.join(current_path, puma_pid_path)))}
          setsid -f env RAILS_ENV=#{esc(@config.fetch(:rails_env))} bundle exec puma -C config/puma.rb --pidfile #{esc(puma_pid_path)} --state #{esc(puma_state_path)} >> log/puma.log 2>&1 < /dev/null
        SH
      end

      wait_for_puma_boot
    end

    def puma_stop
      log 'Stopping Puma'
      run_remote <<~SH
        set -e
        cd #{esc(current_path)}
        if [ -f #{esc(puma_pid_path)} ] && kill -0 "$(cat #{esc(puma_pid_path)})" 2>/dev/null; then
          kill -TERM "$(cat #{esc(puma_pid_path)})"
          rm -f #{esc(puma_pid_path)}
        else
          echo 'Puma is not running'
        fi
      SH
    end

    def puma_restart
      log 'Restarting Puma'
      puma_stop
      puma_start
    end

    def puma_status
      log 'Checking Puma status'
      run_remote <<~SH
        set -e
        cd #{esc(current_path)}
        if [ -f #{esc(puma_pid_path)} ] && kill -0 "$(cat #{esc(puma_pid_path)})" 2>/dev/null; then
          echo 'Puma is running'
        else
          echo 'Puma is not running'
          exit 1
        fi
      SH
    end

    private

    def upload_source(release_path)
      log 'Uploading source via git archive'

      if local_mode?
        run_local <<~SH
          set -e
          git -C #{esc(repo_path)} rev-parse --is-inside-work-tree >/dev/null
          git -C #{esc(repo_path)} archive --format=tar #{esc(branch)} | tar -xf - -C #{esc(release_path)}
        SH
      else
        run_local <<~SH
          set -e
          git -C #{esc(repo_path)} rev-parse --is-inside-work-tree >/dev/null
          git -C #{esc(repo_path)} archive --format=tar #{esc(branch)} | #{ssh_stream_base} "mkdir -p #{esc(release_path)} && tar -xf - -C #{esc(release_path)}"
        SH
      end
    end

    def restart_application
      restart = @config.fetch(:restart_command)
      if restart && !restart.empty?
        log 'Running restart command'
        run_remote(restart)
        return
      end

      return unless @config.fetch(:puma_restart_on_deploy)

      puma_restart
    end

    def wait_for_puma_boot
      run_remote <<~SH
        set -e
        cd #{esc(current_path)}
        for _ in $(seq 1 15); do
          if [ -f #{esc(puma_pid_path)} ] && kill -0 "$(cat #{esc(puma_pid_path)})" 2>/dev/null; then
            exit 0
          fi
          sleep 1
        done
        echo 'Puma failed to start in time'
        exit 1
      SH
    end

    def link_shared_paths(release_path)
      commands = []

      shared_dirs.each do |dir|
        release_dir = File.join(release_path, dir)
        commands << %(mkdir -p #{esc(File.dirname(release_dir))})
        commands << %(rm -rf #{esc(release_dir)})
        commands << %(ln -nfs #{esc(File.join(shared_path, dir))} #{esc(release_dir)})
      end

      shared_files.each do |file|
        if shared_file_covered_by_shared_dir?(file)
          log "Skipping shared file #{file} because its parent directory is already in shared_dirs"
          next
        end

        release_file = File.join(release_path, file)
        shared_file = File.join(shared_path, file)
        commands << %(mkdir -p #{esc(File.dirname(release_file))})
        commands << %(rm -rf #{esc(release_file)})
        commands << %(ln -nfs #{esc(shared_file)} #{esc(release_file)})
      end

      run_remote(commands.join("\n")) unless commands.empty?
    end

    def upload_configured_shared_files
      return if upload_shared_files.empty?

      log 'Uploading configured shared files'
      upload_shared_files.each do |file|
        local_file = File.expand_path(File.join(repo_path, file))
        remote_file = File.join(shared_path, file)

        raise "Configured shared file not found locally: #{local_file}" unless File.file?(local_file)

        run_remote %(mkdir -p #{esc(File.dirname(remote_file))})

        if local_mode?
          run_local %(cp #{esc(local_file)} #{esc(remote_file)})
        else
          destination = "#{ssh_target}:#{remote_file}"
          run_local %(scp -P #{@config.fetch(:port)} #{esc(local_file)} #{esc(destination)})
        end

        run_remote %(chmod 600 #{esc(remote_file)}) if File.basename(file).end_with?('.key')
      end
    end

    def install_dependencies(release_path)
      log 'Installing gems'
      run_remote <<~SH, ruby: true
        set -e
        cd #{esc(release_path)}
        bundle config set path #{esc(bundle_path)}
        bundle config set without #{esc(bundle_withouts)}
        bundle config set deployment 'true'
        bundle install
      SH
    end

    def migrate_db(release_path)
      if force_migrate
        log 'Migrating database'
        run_remote %(cd #{esc(release_path)} && RAILS_ENV=#{esc(@config.fetch(:rails_env))} bundle exec rails db:migrate), ruby: true
        return
      end

      run_remote(
        check_for_changes_script(
          at: migration_dirs,
          release_path: release_path,
          skip: %(echo "-----> DB migrations unchanged; skipping DB migration"),
          changed: %(echo "-----> Migrating database"\ncd #{esc(release_path)} && RAILS_ENV=#{esc(@config.fetch(:rails_env))} bundle exec rails db:migrate)
        ),
        ruby: true
      )
    end

    def precompile_assets(release_path)
      log 'Running rails assets:precompile'
      run_remote %(cd #{esc(release_path)} && RAILS_ENV=#{esc(@config.fetch(:rails_env))} bundle exec rails assets:precompile), ruby: true
    end

    def cleanup_old_releases
      keep = @config.fetch(:keep_releases).to_i
      return if keep <= 0

      log "Cleaning old releases, keeping #{keep}"
      run_remote <<~SH
        set -e
        cd #{esc(releases_path)}
        count=$(ls -1 | wc -l | awk '{print $1}')
        if [ "$count" -gt #{keep} ]; then
          remove=$((count - #{keep}))
          ls -1 | sort | head -n "$remove" | xargs rm -rf
        fi
      SH
    end

    def run_remote(command, ruby: false)
      if local_mode?
        run_local(command)
      else
        remote_command = ruby ? with_remote_ruby(command) : command

        if @remote_batch
          @remote_batch << remote_command
          return
        end

        if @verbose
          remote_command.lines.each do |line|
            text = line.rstrip
            next if text.empty?

            log_command_line(text)
          end
        end
        run_remote_escaped(remote_command)
      end
    end

    def with_remote_batch
      previous_batch = @remote_batch
      @remote_batch = []
      yield

      batched = @remote_batch.join("\n")
      run_remote_escaped(batched) unless batched.strip.empty?
    ensure
      @remote_batch = previous_batch
    end

    def check_for_changes_script(at:, release_path:, skip:, changed:)
      diffs = at.map do |path|
        current_item = esc(File.join(current_path, path))
        release_item = esc(File.join(release_path, path))
        %(([ ! -e #{current_item} ] && [ ! -e #{release_item} ]) || diff -qrN #{current_item} #{release_item} 2>/dev/null)
      end.join(' && ')

      <<~SH
        if #{diffs}
        then
          #{skip}
        else
          #{changed}
        fi
      SH
    end

    def run_local(command, log_command: true)
      if log_command && @verbose
        if @verbose && command.include?("\n")
          lines = command.lines.map(&:rstrip)
          log_command_line(lines.first)
          lines[1..].each do |line|
            next if line.empty?

            log_command_line(line)
          end
        else
          log_command_line(command.lines.first.strip)
        end
      end

      status = nil
      Open3.popen2e('bash', '-lc', command) do |_stdin, output, wait_thread|
        output.each do |line|
          print_process_line(line)
        end
        status = wait_thread.value
      end

      raise 'Command failed' unless status&.success?
    end

    def preview_remote_command(command)
      lines = command.lines.map(&:strip).reject(&:empty?)
      return '(empty command)' if lines.empty?
      return lines.first if lines.length == 1

      "#{lines.first} ... (#{lines.length} lines)"
    end

    def ssh_base
      "ssh -p #{@config.fetch(:port)} #{esc(ssh_target)}"
    end

    def ssh_stream_base
      "ssh -p #{@config.fetch(:port)} #{esc(ssh_target)}"
    end

    def ssh_target
      "#{@config.fetch(:user)}@#{@config.fetch(:host)}"
    end

    def deploy_to
      @config.fetch(:deploy_to)
    end

    def releases_path
      File.join(deploy_to, 'releases')
    end

    def shared_path
      File.join(deploy_to, 'shared')
    end

    def current_path
      File.join(deploy_to, 'current')
    end

    def repo_path
      @config.fetch(:repo_path)
    end

    def branch
      @config.fetch(:branch)
    end

    def puma_state_path
      @config.fetch(:puma_state_path)
    end

    def puma_pid_path
      @config.fetch(:puma_pid_path)
    end

    def shared_dirs
      dirs = @config.fetch(:shared_dirs).dup
      path = bundle_path.to_s.strip
      dirs << path unless path.empty?
      dirs.uniq
    end

    def shared_files
      @config.fetch(:shared_files)
    end

    def upload_shared_files
      @config.fetch(:upload_shared_files)
    end

    def force_migrate
      @config.fetch(:force_migrate)
    end

    def migration_dirs
      @config.fetch(:migration_dirs)
    end

    def bundle_path
      @config.fetch(:bundle_path)
    end

    def bundle_withouts
      @config.fetch(:bundle_withouts)
    end

    def ruby_version
      @config.fetch(:ruby_version)
    end

    def shared_file_covered_by_shared_dir?(file)
      normalized_file = normalize_shared_path(file)

      shared_dirs.any? do |dir|
        normalized_dir = normalize_shared_path(dir)
        normalized_file == normalized_dir || normalized_file.start_with?("#{normalized_dir}/")
      end
    end

    def normalize_shared_path(path)
      path.to_s.gsub(%r{\A/+|/+\z}, '')
    end

    def local_mode?
      @config.fetch(:local_mode)
    end

    def with_remote_ruby(command)
      version = ruby_version
      return command if version.nil? || version.to_s.empty?

      <<~SH
        if [ -s "$HOME/.rvm/scripts/rvm" ]; then
          source "$HOME/.rvm/scripts/rvm"
          rvm use #{esc(version)} >/dev/null
        else
          echo "RVM not found at $HOME/.rvm/scripts/rvm"
          exit 1
        fi
        #{command}
      SH
    end

    def run_remote_escaped(command)
      run_local(%(#{ssh_base} -tt -- #{esc(command)}), log_command: false)
    end

    def esc(value)
      Shellwords.escape(value.to_s)
    end

    def log(message)
      if @remote_batch
        # In batched mode, print status at execution time so output order matches Mina.
        @remote_batch << %(echo #{esc("-----> #{message}")})
      else
        @io.puts("#{color('----->', 32)} #{message}")
      end
    end

    def log_command_line(message)
      @io.puts("       #{color('$', 36)} #{color(message, 36)}")
    end

    def print_process_line(line)
      text = line.to_s.rstrip
      return if text.empty?

      case text
      when /\A-+>\s+(.*)\z/
        @io.puts("#{color('----->', 32)} #{$1}")
      when /\A!\s+(.*)\z/
        @io.puts(" #{color('!', 33)}     #{color($1, 31)}")
      when /\A\$\s+(.*)\z/
        log_command_line($1)
      else
        @io.puts("       #{text}")
      end
    end

    def color(text, code)
      return text if ENV['NO_COLOR']

      "\e[#{code}m#{text}\e[0m"
    end
  end
end
