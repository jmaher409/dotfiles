#!/usr/bin/env ruby
# frozen_string_literal: true
#
# spec-generator.rb — config-driven semantic spec generator
#
# Usage:
#   ruby spec-generator.rb --target=PATH [--scope=name] [--force] [--all] [--model=name]
#
# --target is a path-based identifier:
#   javascript/invoice_list   → matches key 'javascript/' (path-prefix match, item = invoice_list)
#   packs/accounting_domain   → matches key 'packs/'
#   foliospace_integration    → matches key 'foliospace_integration' (flat exact match)
#
# --all (only with path-prefix targets ending in /):
#   Discovers all subdirectories under entry_point_base and runs process_spec for each.
#
# Modes (determined automatically):
#   create     — spec file does not exist: generates from scratch
#   update     — spec file exists, no --force: reads existing spec as LLM context,
#                updates to reflect current code
#   regenerate — spec file exists + --force: ignores existing spec, generates from scratch
#
# The script reads semantic-specs.yml from the repo root to discover source paths.
# Output is written to specifications/ relative to the scope root (or config['output'] path).

require 'optparse'
require 'fileutils'
require 'json'
require 'yaml'
require 'date'
require 'timeout'
require 'open3'

SCRIPT_DIR = File.expand_path('..', File.realpath(__FILE__))
SKILL_DIR   = File.expand_path('..', SCRIPT_DIR)

module SemanticSpecs
  YAML_PERMITTED_CLASSES = [Date, Time, Symbol].freeze
end

require_relative "#{SCRIPT_DIR}/llm_client"
require_relative "#{SCRIPT_DIR}/validate-globs"
require_relative "#{SCRIPT_DIR}/config_resolver"
require_relative "#{SCRIPT_DIR}/frontmatter"
require_relative "#{SCRIPT_DIR}/backend_discovery"
require_relative "#{SCRIPT_DIR}/kuf_cascade"
require_relative "#{SCRIPT_DIR}/spec_processor"

# ============================================================================
# class SemanticSpecGenerator
# ============================================================================
class SemanticSpecGenerator
  include SemanticSpecs::ConfigResolver
  include SemanticSpecs::Frontmatter
  include SemanticSpecs::BackendDiscovery
  include SemanticSpecs::KufCascade
  include SemanticSpecs::SpecProcessor
  include SemanticSpecs::GlobValidation

  CLAUDE_WORKSPACE_DIR = 'tmp/claude_workspace'

  attr_reader :target, :scope_name, :force, :all, :skip_existing, :workers, :model, :verbose, :app_name, :app_path

  def initialize(options)
    @target        = options[:target]
    @scope_name    = options[:scope]
    @force         = options[:force]         || false
    @all           = options[:all]           || false
    @skip_existing = options[:skip_existing] || false
    @workers       = options[:workers]       || 1
    @model         = options[:model]
    @verbose       = options[:verbose]       || false
    @app_name      = options[:app_name]
    @app_path      = options[:app_path]

    # Find repo root and config
    @config_path = find_config_file
    abort_with "semantic-specs.yml not found. Copy the example config:\n  cp #{SKILL_DIR}/config.example.yml semantic-specs.yml" unless @config_path

    @config    = YAML.safe_load(File.read(@config_path), permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES)
    @repo_root = File.dirname(@config_path)
    @root      = resolve_scope_root

    # Workspace for LLM prompts
    @claude_workspace = File.join(@root, CLAUDE_WORKSPACE_DIR)
    FileUtils.mkdir_p(@claude_workspace)

    @llm_client = SemanticSpecs::LlmClient.new(
      root_dir:      @root,
      workspace_dir: @claude_workspace,
      verbose:       @verbose,
      model:         @model
    )

    @glob_validator = SemanticSpecs::Validators::GlobValidator.new(
      root_dir:   @root,
      llm_client: @llm_client
    )

    @repo = derive_repo
    @now  = Time.now.strftime("%Y-%m-%d %H:%M:%S")

    @stats = {
      llm_calls:                    0,
      llm_total_duration:           0.0,
      total_cost_usd:               0.0,
      total_input_tokens:           0,
      total_output_tokens:          0,
      total_cache_write_tokens:     0,
      total_cache_read_tokens:      0,
      specs_generated:              0,
      child_specs_generated:        0,
      analysis_files_generated:     0,
      globs_fixed:                  0,
      body_globs_fixed:             0,
      start_time:                   Time.now
    }
    @stats_mutex  = Mutex.new
    @output_mutex = Mutex.new
  end

  def run
    abort_with "Missing required --target argument" unless target

    if all
      abort_with "--all requires a path-prefix target ending with '/' (e.g. --target=javascript/)" unless target.end_with?('/')
      run_all
    else
      config = if target == 'app_index'
        build_app_index_config
      else
        resolve_spec_config(target)
      end
      abort_with "No spec_paths entry found for target '#{target}' in semantic-specs.yml" unless config

      puts "\n#{"="*60}"
      puts "Target: #{target}#{scope_name ? " | Scope: #{scope_name}" : ""}"
      puts "="*60

      process_spec(config)
    end

    emit_stats
  end

  private

  # ---- All-targets mode ----

  def run_all
    paths = scope_spec_paths
    entry = paths[target]
    abort_with "No spec_paths entry found for prefix '#{target}' in semantic-specs.yml" unless entry

    # Child spec --all mode: entry has a 'parent' key (e.g. target = "javascript.kuf/")
    if entry['parent']
      parent_key   = entry['parent']
      parent_entry = paths[parent_key]
      abort_with "Parent key '#{parent_key}' not found in semantic-specs.yml" unless parent_entry

      entry_point_base = parent_entry['entry_point_base']
      abort_with "entry_point_base required for --all mode (parent key: #{parent_key})" unless entry_point_base

      base_dir = File.join(@root, entry_point_base)
      abort_with "entry_point_base directory not found: #{base_dir}" unless Dir.exist?(base_dir)

      child_type = target.chomp('/').split('.').last

      subdirs = Dir.entries(base_dir).select do |d|
        d != '.' && d != '..' && File.directory?(File.join(base_dir, d))
      end.sort

      abort_with "No subdirectories found under #{entry_point_base}" if subdirs.empty?

      puts "\n#{"="*60}"
      puts "All child specs (#{child_type}) under #{parent_key} | #{subdirs.size} items#{scope_name ? " | Scope: #{scope_name}" : ""}"
      puts "="*60

      run_with_workers(subdirs) do |item_name|
        Thread.current[:log_tag] = item_name
        config = entry.merge(
          '_item_name'  => item_name,
          '_child_type' => child_type,
          '_key'        => target,
          '_parent_key' => parent_key
        )
        puts "\n--- #{parent_key}#{item_name}.#{child_type} ---"
        process_spec(config)
      end
      return
    end

    entry_point_base = entry['entry_point_base']
    abort_with "entry_point_base required for --all mode (key: #{target})" unless entry_point_base

    base_dir = File.join(@root, entry_point_base)
    abort_with "entry_point_base directory not found: #{base_dir}" unless Dir.exist?(base_dir)

    subdirs = Dir.entries(base_dir).select do |d|
      d != '.' && d != '..' && File.directory?(File.join(base_dir, d))
    end.sort

    abort_with "No subdirectories found under #{entry_point_base}" if subdirs.empty?

    puts "\n#{"="*60}"
    puts "All targets under #{target} | #{subdirs.size} items#{scope_name ? " | Scope: #{scope_name}" : ""}#{@workers > 1 ? " | Workers: #{@workers}" : ""}"
    puts "="*60

    run_with_workers(subdirs) do |item_name|
      Thread.current[:log_tag] = item_name
      full_target = "#{target}#{item_name}"
      config = entry.merge('_item_name' => item_name, '_key' => target)
      puts "\n--- #{full_target} ---"
      process_spec(config, full_target)
    end
  end

  def run_with_workers(items, &block)
    if @workers <= 1
      items.each(&block)
      return
    end

    queue = Queue.new
    items.each { |item| queue << item }

    threads = [@workers, items.size].min.times.map do
      Thread.new do
        loop do
          item = queue.pop(true) rescue nil
          break unless item
          block.call(item)
        end
      end
    end
    threads.each(&:join)
  end

  # ---- Mode detection ----

  def determine_mode(spec_path)
    if File.exist?(spec_path)
      force ? :regenerate : :update
    else
      :create
    end
  end

  # ---- LLM ----

  def call_llm(prompt)
    result = @llm_client.call(prompt)

    @stats_mutex.synchronize do
      @stats[:llm_calls]                += 1
      @stats[:llm_total_duration]       += result[:duration]
      @stats[:total_cost_usd]           += result[:cost_usd]
      @stats[:total_input_tokens]       += result[:input_tokens]
      @stats[:total_output_tokens]      += result[:output_tokens]
      @stats[:total_cache_write_tokens] += result[:cache_creation_input_tokens]
      @stats[:total_cache_read_tokens]  += result[:cache_read_input_tokens]
    end

    puts "    Cost: $#{'%.2f' % result[:cost_usd]} | Tokens: #{fmt_num(result[:input_tokens])} in, #{fmt_num(result[:output_tokens])} out, #{fmt_num(result[:cache_creation_input_tokens])} cache-write, #{fmt_num(result[:cache_read_input_tokens])} cache-read"
    @stats_mutex.synchronize do
      puts "    Totals: $#{'%.2f' % @stats[:total_cost_usd]} | #{fmt_num(@stats[:total_input_tokens])} in, #{fmt_num(@stats[:total_output_tokens])} out | #{@stats[:llm_calls]} calls"
    end

    result[:response]
  end

  # ---- Output and logging ----

  def tputs(msg = '')
    tag  = Thread.current[:log_tag]
    line = tag ? "[#{tag}] #{msg}" : msg
    @output_mutex.synchronize { $stdout.puts(line) }
  end

  def puts(msg = '')
    tputs(msg)
  end

  def log(message)
    puts message if verbose
  end

  def abort_with(message)
    $stderr.puts "Error: #{message}"
    exit 1
  end

  def fmt_num(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def format_duration(seconds)
    if seconds < 60
      "#{seconds.round(2)}s"
    else
      minutes = (seconds / 60).floor
      secs = (seconds % 60).round(2)
      "#{minutes}m #{secs}s"
    end
  end

  # ---- Stats ----

  def emit_stats
    total_duration    = Time.now - @stats[:start_time]
    avg_llm_duration  = @stats[:llm_calls] > 0 ? @stats[:llm_total_duration] / @stats[:llm_calls] : 0

    puts "\n" + "="*60
    puts "Statistics"
    puts "="*60
    puts "Total duration:               #{format_duration(total_duration)}"
    puts "LLM calls:                    #{@stats[:llm_calls]}"
    puts "LLM total duration:           #{format_duration(@stats[:llm_total_duration])}"
    puts "LLM average duration:         #{format_duration(avg_llm_duration)}"
    puts "Total cost:                   $#{'%.2f' % @stats[:total_cost_usd]}"
    puts "Total tokens in:              #{fmt_num(@stats[:total_input_tokens])}"
    puts "Total tokens out:             #{fmt_num(@stats[:total_output_tokens])}"
    puts "Total cache write:            #{fmt_num(@stats[:total_cache_write_tokens])}"
    puts "Total cache read:             #{fmt_num(@stats[:total_cache_read_tokens])}"
    puts "Specs generated:              #{@stats[:specs_generated]}"
    puts "Child specs generated:        #{@stats[:child_specs_generated]}"
    puts "Analysis files generated:     #{@stats[:analysis_files_generated]}"
    puts "Globs fixed (frontmatter):    #{@stats[:globs_fixed]}"
    puts "Body globs fixed:             #{@stats[:body_globs_fixed]}"
    puts "Glob cache hits:              #{SemanticSpecs::Validators::GlobValidator.cache_hits}"
    puts "="*60
  end
end

# ============================================================================
# CLI
# ============================================================================
if __FILE__ == $0
options = {}

OptionParser.new do |opts|
  opts.banner = "Usage: spec-generator.rb --target=PATH [options]"

  opts.on('--target=PATH',  'Target path (e.g. javascript/invoice_list, packs/my_pack, foliospace_integration)') { |v| options[:target]  = v }
  opts.on('--scope=NAME',   'Scope name (multi-scope repos)')                                                    { |v| options[:scope]   = v }
  opts.on('--force',         'Regenerate from scratch (ignore existing spec)')                                   { options[:force]          = true }
  opts.on('--skip-existing', 'Skip specs that already exist — only generate missing ones')                       { options[:skip_existing]  = true }
  opts.on('--all',          'Generate specs for all items under a path-prefix target (requires target ending in /)') { options[:all] = true }
  opts.on('--workers=N',    Integer, 'Number of parallel workers for --all (default: 1)')                        { |v| options[:workers] = v }
  opts.on('--model=NAME',    "LLM model (default: otto default)")                                              { |v| options[:model]    = v }
  opts.on('--app-name=NAME', 'App name for app_index target (defaults to scope name)')                         { |v| options[:app_name] = v }
  opts.on('--app-path=PATH', 'App path for app_index target (defaults to scope root)')                         { |v| options[:app_path] = v }
  opts.on('--list',          'List all configured spec targets and exit')                                      { options[:list] = true }
  opts.on('-v', '--verbose', 'Verbose output')                                                                  { options[:verbose] = true }
  opts.on('-h', '--help',   'Show help') { puts opts; exit 0 }
end.parse!

if options[:list]
  config_path = Dir.glob('{.,..,..\\..,../../..}/semantic-specs.yml').first
  abort "semantic-specs.yml not found" unless config_path
  config = YAML.safe_load(File.read(config_path))
  puts "\nConfigured spec targets in #{File.basename(config_path)}:\n"
  repo_root = File.dirname(config_path)

  print_targets = lambda do |spec_paths, scope_name, scope_root|
    spec_paths.each do |key, entry|
      scope_flag = scope_name ? " --scope=#{scope_name}" : ""
      puts "  --target=#{key}#{scope_flag}"
      next unless key.end_with?('/')
      entry_base = entry.is_a?(Hash) ? entry['entry_point_base'] : nil
      next unless entry_base
      full_base = File.join(scope_root || repo_root, entry_base)
      examples = Dir.glob("#{full_base.chomp('/')}/*").select { |d| File.directory?(d) }.first(3)
      examples.each do |d|
        item = "#{key.chomp('/')}/" + File.basename(d)
        puts "    e.g. --target=#{item}#{scope_flag}"
      end
    end
  end

  if config['scopes']
    config['scopes'].each do |scope_name, scope_config|
      scope_root = scope_config['root'] ? File.join(repo_root, scope_config['root']) : repo_root
      puts "\nScope: #{scope_name}"
      print_targets.call(scope_config['spec_paths'] || {}, scope_name, scope_root)
    end
  end
  if config['spec_paths']
    puts "\nRoot-level:"
    print_targets.call(config['spec_paths'], nil, repo_root)
  end
  puts
  exit 0
end

generator = SemanticSpecGenerator.new(options)
generator.run
end # if __FILE__ == $0
