# frozen_string_literal: true

require 'fileutils'
require 'optparse'

module Mira
  class CLI
    COMMANDS = %w[init setup deploy rollback puma:start puma:stop puma:restart puma:status version help].freeze

    def self.start(argv)
      new(argv).start
    end

    def initialize(argv)
      @argv = argv.dup
      @options = { verbose: false, environment: nil }
    end

    def start
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      parse_options!
      command = resolve_command!
      return print_help if command.nil? || command == 'help'

      unless COMMANDS.include?(command)
        warn "Unknown command: #{command}"
        return print_help(1)
      end

      run_command(command)
      print_elapsed_time(started_at)
      0
    rescue StandardError => e
      warn "Error: #{e.message}"
      1
    end

    private

    def parse_options!
      OptionParser.new do |opts|
        opts.on('-v', '--verbose', 'Show full command logs') do
          @options[:verbose] = true
        end
      end.permute!(@argv)
    rescue OptionParser::ParseError => e
      raise ArgumentError, e.message
    end

    def run_init
      target = File.expand_path('Mirafile', Dir.pwd)
      raise 'Mirafile already exists' if File.exist?(target)

      template = File.expand_path('../../templates/Mirafile', __dir__)
      FileUtils.cp(template, target)
      puts 'Created Mirafile'
    end

    def run_setup
      deployer.setup
    end

    def run_deploy
      deployer.deploy
    end

    def run_rollback
      deployer.rollback
    end

    def run_version
      puts Mira::VERSION
    end

    def run_command(command)
      case command
      when 'init' then run_init
      when 'setup' then run_setup
      when 'deploy' then run_deploy
      when 'rollback' then run_rollback
      when 'puma:start' then deployer.puma_start
      when 'puma:stop' then deployer.puma_stop
      when 'puma:restart' then deployer.puma_restart
      when 'puma:status' then deployer.puma_status
      when 'version' then run_version
      else
        print_help(1)
      end
    end

    def load_config
      path = File.expand_path('Mirafile', Dir.pwd)
      raise 'Mirafile not found in current directory, run `mira init` first' unless File.exist?(path)

      Config.load(path, selected_environment: @options[:environment])
    end

    def resolve_command!
      token = @argv.shift
      return nil if token.nil?
      return token if COMMANDS.include?(token)

      @options[:environment] = token
      @argv.shift
    end

    def deployer
      @deployer ||= Deployer.new(load_config, verbose: @options[:verbose])
    end

    def print_help(exit_code = 0)
      puts <<~HELP
        mira - minimal Rails 8 deploy tool

        Usage:
          mira [--verbose] init
          mira [--verbose] setup
          mira [--verbose] deploy
          mira [--verbose] [environment] setup
          mira [--verbose] [environment] deploy
          mira [--verbose] [environment] rollback
          mira [--verbose] rollback
          mira [--verbose] puma:start
          mira [--verbose] puma:stop
          mira [--verbose] puma:restart
          mira [--verbose] puma:status
          mira [--verbose] version

        Notes:
          - Run commands from the app directory where Mirafile exists.
          - Optional environment follows Mina style: `mira staging deploy`.
          - Define environments in Mirafile with `environment 'name' do ... end`.
          - setup prepares shared and releases directories on remote host.
          - deploy uploads code from local git branch, runs Rails tasks, then restarts Puma.
      HELP
      exit_code
    end

    def print_elapsed_time(started_at)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts "\n       Elapsed time: #{format('%.2f', elapsed)} seconds"
    end
  end
end
