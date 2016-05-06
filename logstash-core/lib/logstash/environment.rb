# encoding: utf-8
require "logstash/errors"
require "logstash/config/cpu_core_strategy"
require "logstash/settings"

module LogStash

  [
                  Setting.new("node.name", String, Socket.gethostname),
           BooleanSetting.new("config.allow_env", false),
  ExistingFilePathSetting.new("config.path", nil, false),
                  Setting.new("config.string", String, nil, false),
           BooleanSetting.new("config.test", false),
           BooleanSetting.new("config.auto_reload", false),
                  Setting.new("config.reload_interval", Numeric, 3),
           BooleanSetting.new("metric.collect", false),
                  Setting.new("pipeline.id", String, "main"),
                  Setting.new("pipeline.workers", Numeric, LogStash::Config::CpuCoreStrategy.maximum),
                  Setting.new("pipeline.output.workers", Numeric, 1),
                  Setting.new("pipeline.batch.size", Numeric, 125),
                  Setting.new("pipeline.batch.delay", Numeric, 5), # in milliseconds
           BooleanSetting.new("pipeline.unsafe_shutdown", false),
                  Setting.new("plugin.paths", Array, []),
                  Setting.new("ruby_shell", String, nil, false),
           BooleanSetting.new("debug", false),
           BooleanSetting.new("debug.config", false),
           BooleanSetting.new("verbose", false),
           BooleanSetting.new("quiet", false),
           BooleanSetting.new("version", false),
           BooleanSetting.new("help", false),
                  Setting.new("log.path", String, nil, false),
                  Setting.new("web_api.http.host", String, "127.0.0.1"),
                  Setting.new("web_api.http.port", Numeric, 9600),
  ].each {|setting| SETTINGS.register(setting) }

  module Environment
    extend self

    LOGSTASH_CORE = ::File.expand_path(::File.join(::File.dirname(__FILE__), "..", ".."))
    LOGSTASH_ENV = (ENV["LS_ENV"] || 'production').to_s.freeze

    def env
      LOGSTASH_ENV
    end

    def production?
      env.downcase == "production"
    end

    def development?
      env.downcase == "development"
    end

    def test?
      env.downcase == "test"
    end

    def runtime_jars_root(dir_name, package)
      ::File.join(dir_name, package, "runtime-jars")
    end

    def test_jars_root(dir_name, package)
      ::File.join(dir_name, package, "test-jars")
    end

    def load_runtime_jars!(dir_name="vendor", package="jar-dependencies")
      load_jars!(::File.join(runtime_jars_root(dir_name, package), "*.jar"))
    end

    def load_test_jars!(dir_name="vendor", package="jar-dependencies")
      load_jars!(::File.join(test_jars_root(dir_name, package), "*.jar"))
    end

    def load_jars!(pattern)
      raise(LogStash::EnvironmentError, I18n.t("logstash.environment.jruby-required")) unless LogStash::Environment.jruby?

      jar_files = find_jars(pattern)
      require_jars! jar_files
    end

    def find_jars(pattern)
      require 'java'
      jar_files = Dir.glob(pattern)
      raise(LogStash::EnvironmentError, I18n.t("logstash.environment.missing-jars", :pattern => pattern)) if jar_files.empty?
      jar_files
    end

    def require_jars!(files)
      files.each do |jar_file|
        loaded = require jar_file
        puts("Loaded #{jar_file}") if $DEBUG && loaded
      end
    end

    def ruby_bin
      ENV["USE_RUBY"] == "1" ? "ruby" : File.join("vendor", "jruby", "bin", "jruby")
    end

    def jruby?
      @jruby ||= !!(RUBY_PLATFORM == "java")
    end

    def windows?
      ::Gem.win_platform?
    end

    def locales_path(path)
      return ::File.join(LOGSTASH_CORE, "locales", path)
    end

    def load_locale!
      require "i18n"
      I18n.enforce_available_locales = true
      I18n.load_path << LogStash::Environment.locales_path("en.yml")
      I18n.reload!
      fail "No locale? This is a bug." if I18n.available_locales.empty?
    end

    # add path for bare/ungemified plugins lookups. the path must be the base path that will include
    # the dir structure 'logstash/TYPE/NAME.rb' where TYPE is 'inputs' 'filters', 'outputs' or 'codecs'
    # and NAME is the name of the plugin
    # @param path [String] plugins path to add
    def add_plugin_path(path)
      $LOAD_PATH << path
    end
  end
end

require "logstash/patches"
