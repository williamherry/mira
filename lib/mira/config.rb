# frozen_string_literal: true

module Mira
  class Config
    DEFAULTS = {
      host: nil,
      user: nil,
      port: 22,
      local_mode: false,
      ruby_version: nil,
      deploy_to: nil,
      repo_path: '.',
      branch: 'main',
      rails_env: 'production',
      keep_releases: 5,
      migrate: true,
      force_migrate: false,
      migration_dirs: ['db/migrate'],
      precompile_assets: true,
      bundle_path: 'vendor/bundle',
      bundle_withouts: 'development test',
      puma_restart_on_deploy: true,
      puma_start_command: nil,
      puma_state_path: 'tmp/pids/puma.state',
      puma_pid_path: 'tmp/pids/puma.pid',
      restart_command: nil,
      shared_dirs: ['log', 'tmp/pids', 'tmp/cache', 'public/uploads'],
      shared_files: [],
      upload_shared_files: []
    }.freeze

    class DSLContext
      def initialize(config)
        @config = config
      end

      def set(key, value)
        @config.set(key, value)
      end

      def environment(name, &block)
        @config.register_environment(name, block)
      end
    end

    def self.load(path, selected_environment: nil)
      config = new
      DSLContext.new(config).instance_eval(File.read(path), path)
      config.finalize!(selected_environment: selected_environment)
      config
    end

    def initialize
      @values = {}
      @environments = {}
      DEFAULTS.each { |k, v| @values[k] = duplicate(v) }
    end

    def set(key, value)
      @values[key.to_sym] = value
    end

    def fetch(key)
      @values.fetch(key.to_sym)
    end

    def register_environment(name, block)
      raise ArgumentError, 'environment requires a block' unless block

      @environments[name.to_s] = block
    end

    def finalize!(selected_environment: nil)
      apply_environment!(selected_environment) if selected_environment

      required = %i[host user deploy_to]
      missing = required.select { |key| blank?(fetch(key)) }
      return if missing.empty?

      raise ArgumentError, "Missing required settings: #{missing.join(', ')}"
    end

    private

    def duplicate(value)
      value.is_a?(Array) ? value.dup : value
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def apply_environment!(selected_environment)
      env_name = selected_environment.to_s
      block = @environments[env_name]
      return DSLContext.new(self).instance_exec(&block) if block

      available = @environments.keys.sort
      if available.empty?
        raise ArgumentError, "Environment '#{env_name}' is not defined"
      end

      raise ArgumentError, "Environment '#{env_name}' is not defined (available: #{available.join(', ')})"
    end
  end
end
