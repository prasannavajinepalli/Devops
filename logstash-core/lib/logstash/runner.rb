# encoding: utf-8
Thread.abort_on_exception = true
Encoding.default_external = Encoding::UTF_8
$DEBUGLIST = (ENV["DEBUG"] || "").split(",")

require "clamp"
require "cabin"
require "net/http"
require "logstash/environment"

LogStash::Environment.load_locale!

require "logstash/namespace"
require "logstash/agent"
require "logstash/config/defaults"
require "logstash/shutdown_watcher"

#puts "defining writer for #{option.attribute_name}"
#puts "setting #{value}(class #{value.class}) for #{option.attribute_name}"
#puts "getting value for #{option.attribute_name}"
module Clamp
  module Attribute
    class Instance
      def default_from_environment
        # we don want uncontrolled var injection from the environment
      end
    end
  end

  module Option

    module Declaration

      include Clamp::Attribute::Declaration

      def define_simple_writer_for(option, &block)
        LogStash::SETTINGS.get(option.attribute_name)
        define_method(option.write_method) do |value|
          value = instance_exec(value, &block) if block
          LogStash::SETTINGS.set_value(option.attribute_name, value)
        end
      end

      def define_reader_for(option)
        define_method(option.read_method) do
          LogStash::SETTINGS.get_value(option.attribute_name)
        end
      end
    end
  end
end

class LogStash::Runner < Clamp::Command

  # Node Settings
  option ["-n", "--node.name"], "NAME",
    I18n.t("logstash.runner.flag.node_name"),
    :attribute_name => "node.name",
    :default => LogStash::SETTINGS.get_default("node.name")

  # Config Settings
  option ["-f", "--config.path"], "CONFIG_PATH",
    I18n.t("logstash.runner.flag.config"),
    :attribute_name => "config.path"

  option ["-e", "--config.string"], "CONFIG_STRING",
    I18n.t("logstash.runner.flag.config-string",
      :default_input => LogStash::Config::Defaults.input,
      :default_output => LogStash::Config::Defaults.output),
    :default => LogStash::SETTINGS.get_default("config.string"),
    :attribute_name => "config.string"

  # Pipeline settings
  option ["-w", "--pipeline.workers"], "COUNT",
    I18n.t("logstash.runner.flag.pipeline-workers"),
    :attribute_name => "pipeline.workers",
    :default => LogStash::SETTINGS.get_default("pipeline.workers"), &:to_i

  option ["-b", "--pipeline.batch.size"], "SIZE",
    I18n.t("logstash.runner.flag.pipeline-batch-size"),
    :attribute_name => "pipeline.batch.size",
    :default => LogStash::SETTINGS.get_default("pipeline.batch.size"), &:to_i

  option ["-u", "--pipeline.batch.delay"], "DELAY_IN_MS",
    I18n.t("logstash.runner.flag.pipeline-batch-delay"),
    :attribute_name => "pipeline.batch.delay",
    :default => LogStash::SETTINGS.get_default("pipeline.batch.delay")

  option ["--[no-]pipeline.unsafe_shutdown"], :flag,
    I18n.t("logstash.runner.flag.unsafe_shutdown"),
    :attribute_name => "pipeline.unsafe_shutdown",
    :default => LogStash::SETTINGS.get_default("pipeline.unsafe_shutdown")

  # Plugins Settings
  option ["-p", "--plugin.paths"] , "PATH",
    I18n.t("logstash.runner.flag.pluginpath"),
    :multivalued => true, :attribute_name => "plugin.paths",
    :default => LogStash::SETTINGS.get_default("plugin.paths")

  # Logging Settings
  option ["-l", "--log"], "FILE",
    I18n.t("logstash.runner.flag.log"),
    :attribute_name => "log.path"

  option "--[no-]debug", :flag, I18n.t("logstash.runner.flag.debug"),
    :default => LogStash::SETTINGS.get_default("debug")
  option "--[no-]quiet", :flag, I18n.t("logstash.runner.flag.quiet"),
    :default => LogStash::SETTINGS.get_default("quiet")
  option "--[no-]verbose", :flag, I18n.t("logstash.runner.flag.verbose"),
    :default => LogStash::SETTINGS.get_default("verbose")

  option "--debug.config", :flag,
    I18n.t("logstash.runner.flag.debug_config"),
    :default => LogStash::SETTINGS.get_default("debug.config"),
    :attribute_name => "debug.config"

  # Other settings
  option ["-i", "--interactive"], "SHELL",
    I18n.t("logstash.runner.flag.rubyshell"),
    :attribute_name => "ruby_shell"

  option ["-V", "--version"], :flag,
    I18n.t("logstash.runner.flag.version")

  option ["-t", "--[no-]config.test"], :flag,
    I18n.t("logstash.runner.flag.configtest"),
    :attribute_name => "config.test",
    :default => LogStash::SETTINGS.get_default("config.test")

  option ["-r", "--[no-]auto.reload"], :flag,
    I18n.t("logstash.runner.flag.auto_reload"),
    :attribute_name => "config.auto_reload", :default => false

  option ["--reload.interval"], "RELOAD_INTERVAL",
    I18n.t("logstash.runner.flag.reload_interval"),
    :attribute_name => "config.reload_interval", :default => 3, &:to_i

  option ["--http-host"], "WEB_API_HTTP_HOST",
    I18n.t("logstash.web_api.flag.http_host"),
    :attribute_name => "web_api.http.host", :default => "127.0.0.1"

  option ["--http-port"], "WEB_API_HTTP_PORT",
    I18n.t("logstash.web_api.flag.http_port"),
    :attribute_name => "web_api.http.port", :default => 9600, &:to_i

  option ["--allow-env"], :flag,
    I18n.t("logstash.runner.flag.allow-env"),
    :attribute_name => "config.allow_env", :default => false

  attr_reader :agent

  def initialize(*args)
    @logger = Cabin::Channel.get(LogStash)
    @settings = LogStash::SETTINGS
    super(*args)
  end

  def execute
    require "logstash/util"
    require "logstash/util/java_version"
    require "stud/task"
    require "cabin" # gem 'cabin'

    # Configure Logstash logging facility, this need to be done before everything else to
    # make sure the logger has the correct settings and the log level is correctly defined.
    configure_logging(setting("log.path"))

    LogStash::Util::set_thread_name(self.class.name)

    if RUBY_VERSION < "1.9.2"
      $stderr.puts "Ruby 1.9.2 or later is required. (You are running: " + RUBY_VERSION + ")"
      return 1
    end

    # Exit on bad java versions
    java_version = LogStash::Util::JavaVersion.version
    if LogStash::Util::JavaVersion.bad_java_version?(java_version)
      $stderr.puts "Java version 1.8.0 or later is required. (You are running: #{java_version})"
      return 1
    end  

    LogStash::ShutdownWatcher.unsafe_shutdown = setting("pipeline.unsafe_shutdown")
    LogStash::ShutdownWatcher.logger = @logger

    configure_plugin_paths(setting("plugin.paths"))

    if version?
      show_version
      return 0
    end

    return start_shell(setting("ruby_shell"), binding) if setting("ruby_shell")

    @settings.format_settings.each {|line| @logger.log(line) }

    if setting("config.string").nil? && setting("config.path").nil?
      fail(I18n.t("logstash.runner.missing-configuration"))
    end

    if setting("config.auto_reload") && setting("config.path").nil?
      # there's nothing to reload
      signal_usage_error(I18n.t("logstash.runner.reload-without-config-path"))
    end

    if setting("config.test")
      config_loader = LogStash::Config::Loader.new(@logger)
      config_str = config_loader.format_config(setting("config.path"), setting("config.string"))
      begin
        LogStash::Pipeline.new(config_str)
        @logger.terminal "Configuration OK"
        return 0
      rescue => e
        @logger.fatal I18n.t("logstash.runner.invalid-configuration", :error => e.message)
        return 1
      end
    end

    @agent = create_agent(@settings)

    @agent.register_pipeline("main", @settings)

    # enable sigint/sigterm before starting the agent
    # to properly handle a stalled agent
    sigint_id = trap_sigint()
    sigterm_id = trap_sigterm()

    @agent_task = Stud::Task.new { @agent.execute }

    # no point in enabling config reloading before the agent starts
    sighup_id = trap_sighup()

    agent_return = @agent_task.wait

    @agent.shutdown

    agent_return

  rescue Clamp::UsageError => e
    $stderr.puts "ERROR: #{e.message}"
    show_short_help
    return 1
  rescue => e
    @logger.fatal(I18n.t("oops"), :error => e, :backtrace => e.backtrace)
    return 1
  ensure
    Stud::untrap("INT", sigint_id) unless sigint_id.nil?
    Stud::untrap("TERM", sigterm_id) unless sigterm_id.nil?
    Stud::untrap("HUP", sighup_id) unless sighup_id.nil?
    @log_fd.close if @log_fd
  end # def self.main

  def show_version
    show_version_logstash

    if [:info, :debug].include?(verbosity?) || debug? || verbose?
      show_version_ruby
      show_version_java if LogStash::Environment.jruby?
      show_gems if [:debug].include?(verbosity?) || debug?
    end
  end # def show_version

  def show_version_logstash
    require "logstash/version"
    puts "logstash #{LOGSTASH_VERSION}"
  end # def show_version_logstash

  def show_version_ruby
    puts RUBY_DESCRIPTION
  end # def show_version_ruby

  def show_version_java
    properties = java.lang.System.getProperties
    puts "java #{properties["java.version"]} (#{properties["java.vendor"]})"
    puts "jvm #{properties["java.vm.name"]} / #{properties["java.vm.version"]}"
  end # def show_version_java

  def show_gems
    require "rubygems"
    Gem::Specification.each do |spec|
      puts "gem #{spec.name} #{spec.version}"
    end
  end # def show_gems

  # add the given paths for ungemified/bare plugins lookups
  # @param paths [String, Array<String>] plugins path string or list of path strings to add
  def configure_plugin_paths(paths)
    Array(paths).each do |path|
      fail(I18n.t("logstash.runner.configuration.plugin_path_missing", :path => path)) unless File.directory?(path)
      LogStash::Environment.add_plugin_path(path)
    end
  end

  def create_agent(*args)
    LogStash::Agent.new(*args)
  end

  # Point logging at a specific path.
  def configure_logging(path)
    @logger = Cabin::Channel.get(LogStash)
    # Set with the -v (or -vv...) flag
    if quiet?
      @logger.level = :error
    elsif verbose?
      @logger.level = :info
    elsif debug?
      @logger.level = :debug
    else
      @logger.level = :warn
    end

    if path
      # TODO(sissel): Implement file output/rotation in Cabin.
      # TODO(sissel): Catch exceptions, report sane errors.
      begin
        @log_fd.close if @log_fd
        @log_fd = File.new(path, "a")
      rescue => e
        fail(I18n.t("logstash.runner.configuration.log_file_failed",
                    :path => path, :error => e))
      end

      @logger.subscribe(STDOUT, :level => :fatal)
      @logger.subscribe(@log_fd)
      @logger.terminal "Sending logstash logs to #{path}."
    else
      @logger.subscribe(STDOUT)
    end

    if setting("debug.config") && @logger.level != :debug
      @logger.warn("--debug-config was specified, but log level was not set to --debug! No config info will be logged.")
    end

    # TODO(sissel): redirect stdout/stderr to the log as well
    # http://jira.codehaus.org/browse/JRUBY-7003
  end # def configure_logging

  # Emit a failure message and abort.
  def fail(message)
    signal_usage_error(message)
  end # def fail

  def show_short_help
    puts I18n.t("logstash.runner.short-help")
  end

  def start_shell(shell, start_binding)
    case shell
    when "pry"
      require 'pry'
      start_binding.pry
    when "irb"
      require 'irb'
      ARGV.clear
      # TODO: set binding to this instance of Runner
      # currently bugged as per https://github.com/jruby/jruby/issues/384
      IRB.start(__FILE__)
    else
      fail(I18n.t("logstash.runner.invalid-shell"))
    end
  end

  def trap_sighup
    Stud::trap("HUP") do
      @logger.warn(I18n.t("logstash.agent.sighup"))
      @agent.reload_state!
    end
  end

  def trap_sigterm
    Stud::trap("TERM") do
      @logger.warn(I18n.t("logstash.agent.sigterm"))
      @agent_task.stop!
    end
  end

  def trap_sigint
    Stud::trap("INT") do
      if @interrupted_once
        @logger.fatal(I18n.t("logstash.agent.forced_sigint"))
        exit
      else
        @logger.warn(I18n.t("logstash.agent.sigint"))
        Thread.new(@logger) {|logger| sleep 5; logger.warn(I18n.t("logstash.agent.slow_shutdown")) }
        @interrupted_once = true
        @agent_task.stop!
      end
    end
  end

  def setting(key)
    @settings.get_value(key)
  end
end
