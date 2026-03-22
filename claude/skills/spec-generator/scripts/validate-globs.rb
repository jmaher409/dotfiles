#!/usr/bin/env ruby
# frozen_string_literal: true
#
# validate-globs.rb — glob validator with LLM-assisted retry
#
# Can be used three ways:
#
#   1. Required from spec-generator.rb:
#      require_relative 'validate-globs'
#      validator = SemanticSpecs::Validators::GlobValidator.new(root_dir: ..., llm_client: ...)
#      fixed = validator.validate_with_retry(pattern, context)
#
#   2. Mixed into SemanticSpecGenerator via SemanticSpecs::GlobValidation:
#      Provides validate_and_fix_globs, validate_and_fix_body_globs, and related methods.
#
#   3. Standalone CLI:
#      ruby validate-globs.rb <glob_pattern> [--root=<dir>] [--feature=<name>] [--field=<name>]
#      ruby validate-globs.rb <glob_pattern> --no-retry   # validate only, no LLM

SCRIPT_DIR = File.expand_path('..', File.realpath(__FILE__))

module SemanticSpecs
  module Validators
    class GlobValidator
      MAX_ATTEMPTS = 3

      # Shared across all instances in a single process run — persists through --all
      CACHE       = {}
      CACHE_MUTEX = Mutex.new
      @cache_hits = 0

      class << self
        attr_accessor :cache_hits
      end

      attr_reader :root_dir, :llm_client

      def initialize(root_dir:, llm_client:)
        @root_dir = root_dir
        @llm_client = llm_client
      end

      def validate_with_retry(glob_pattern, context = {})
        cache_key = "glob_validation:#{glob_pattern}"
        indent = context[:indent] || "    "

        cached = CACHE_MUTEX.synchronize { CACHE[cache_key] }
        if cached
          if cached == glob_pattern
            puts "#{indent}Validating: #{glob_pattern} (cached ok)"
          else
            puts "#{indent}Validating: #{glob_pattern} (cached fix → #{cached})"
          end
          CACHE_MUTEX.synchronize { GlobValidator.cache_hits += 1 }
          return cached
        end

        attempts = 0
        current_glob = glob_pattern
        original_glob = glob_pattern

        puts "#{indent}Validating: #{current_glob}"

        while attempts < MAX_ATTEMPTS
          matches = Dir.glob(File.join(root_dir, current_glob))

          if matches.any?
            puts "#{indent}  ok (#{matches.size} matches)"
            CACHE_MUTEX.synchronize { CACHE[cache_key] = current_glob }
            return current_glob
          end

          attempts += 1
          if attempts >= MAX_ATTEMPTS
            puts "#{indent}  no matches after #{MAX_ATTEMPTS} attempts: #{original_glob}"
            CACHE_MUTEX.synchronize { CACHE[cache_key] = original_glob }
            return original_glob
          end

          puts "#{indent}  no matches, requesting LLM fix (attempt #{attempts}/#{MAX_ATTEMPTS - 1})..."
          current_glob, _ = request_glob_fix(current_glob, context, "No files matched in #{root_dir}")
        end

        CACHE_MUTEX.synchronize { CACHE[cache_key] = current_glob }
        current_glob
      rescue StandardError => e
        puts "    error during glob validation: #{e.message}"
        glob_pattern
      end

      def request_glob_fix(failed_glob, context, error_message)
        prompt = build_fix_prompt(failed_glob, context, error_message)
        response = llm_client.call(prompt)[:response]

        # Only accept a GLOB: prefixed line — never treat prose as a glob pattern
        glob_line = response.lines.map(&:strip).find { |l| l.start_with?('GLOB:') }
        corrected = glob_line ? glob_line.sub(/^GLOB:\s*/, '').strip : nil

        [corrected || failed_glob, response]
      end

      private

      def build_fix_prompt(failed_glob, context, error_message)
        if context[:kuf]
          build_kuf_prompt(failed_glob, context, error_message)
        else
          build_feature_prompt(failed_glob, context, error_message)
        end
      end

      def build_kuf_prompt(failed_glob, context, error_message)
        kuf         = context[:kuf]
        frontmatter = context[:frontmatter]

        <<~PROMPT
          SYSTEM INSTRUCTIONS:
          - Role: corrector
          - Output Format: single_line
          - Automation Mode: true (no questions, no explanations)

          OUTPUT REQUIREMENTS:
          - Your response must be EXACTLY in this format on a single line:
            GLOB: <pattern>
          - Example: GLOB: app/javascript/feature/**/*.spec.ts
          - Do NOT include any other text before or after the GLOB: line
          - Do NOT explain your reasoning
          - Do NOT describe what you're doing
          - MUST be valid Ruby Dir.glob pattern

          CRITICAL - RUBY GLOB REQUIREMENTS:
          - DO NOT use brace expansion: {file1,file2} - NOT SUPPORTED IN RUBY
          - DO NOT use comma-separated lists in braces
          - Valid wildcards: ** (recursive), * (single level), ? (single char)
          - Valid: app/javascript/feature/**/*.spec.ts
          - Valid: app/javascript/feature/components/**/*
          - INVALID: app/javascript/{file1,file2,file3}
          - INVALID: app/**/{models,controllers}/*.rb

          OUTPUT FORMAT (use this exact format):
          GLOB: app/javascript/payments/one_time_payment/**/*

          ---

          TASK:
          Fix an invalid KUF glob pattern.

          Feature: #{context[:feature_name]}
          KUF Flow: #{kuf[:flow_name]}
          Failed glob: #{failed_glob}
          Error: #{error_message}

          Valid feature-level globs (corrected):
          - frontend_paths: #{frontmatter['frontend_paths'].to_json}
          - backend_paths: #{frontmatter['backend_paths'].to_json}


          Flow Gherkin steps:
          #{kuf[:gherkin]}

          Determine which SPECIFIC files from the feature-level paths are involved in THIS flow.
          Return ONLY the line: GLOB: <pattern>
        PROMPT
      end

      def build_feature_prompt(failed_glob, context, error_message)
        <<~PROMPT
          SYSTEM INSTRUCTIONS:
          - Role: corrector
          - Output Format: single_line
          - Automation Mode: true (no questions, no explanations)

          OUTPUT REQUIREMENTS:
          - Your response must be EXACTLY in this format on a single line:
            GLOB: <pattern>
          - Example: GLOB: app/javascript/feature_name/**/*
          - Do NOT include any other text before or after the GLOB: line
          - Do NOT explain your reasoning
          - Do NOT describe what you're doing
          - MUST be valid Ruby Dir.glob pattern

          CRITICAL - RUBY GLOB REQUIREMENTS:
          - DO NOT use brace expansion: {file1,file2} - NOT SUPPORTED IN RUBY
          - DO NOT use comma-separated lists in braces
          - Valid wildcards: ** (recursive), * (single level), ? (single char)
          - Valid: app/javascript/feature/**/*.spec.ts
          - Valid: app/javascript/feature/components/**/*
          - INVALID: app/javascript/{file1,file2,file3}
          - INVALID: app/**/{models,controllers}/*.rb

          OUTPUT FORMAT (use this exact format):
          GLOB: app/javascript/feature_name/**/*

          COMMON ISSUES TO CHECK:
          - Brace expansion (shell syntax, not Ruby)
          - Missing wildcards (** for recursive, * for single level)
          - Incorrect path separators
          - Wrong directory structure
          - Missing file extensions
          - Typos in pack/directory names

          ---

          TASK:
          Correct an invalid glob pattern in a feature specification.

          Feature: #{context[:feature_name]}
          Field: #{context[:field_name]}
          Failed glob pattern: #{failed_glob}
          Error: #{error_message}

          Return ONLY the line: GLOB: <corrected_pattern>
        PROMPT
      end
    end
  end
end

module SemanticSpecs
  # Glob validation methods mixed into SemanticSpecGenerator.
  # Validates and corrects glob patterns in spec frontmatter and KUF body tables.
  module GlobValidation
    private

    def validate_and_fix_globs(spec_path, feature_name, glob_fields = %w[frontend_paths backend_paths])
      puts "  Validating globs..."

      content = File.read(spec_path)

      yaml_match = content.match(/^---\n(.*?)\n---\n/m)
      unless yaml_match
        log "Warning: Could not parse YAML frontmatter in #{spec_path}"
        return
      end

      begin
        frontmatter = YAML.safe_load(yaml_match[1], permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
      rescue Psych::Exception => e
        puts "  Could not parse frontmatter for glob validation: #{e.message}"
        return
      end

      return unless frontmatter.is_a?(Hash)

      needs_update = false

      glob_fields.each do |field|
        next unless frontmatter[field].is_a?(Array)

        frontmatter[field].map! do |glob_pattern|
          next glob_pattern unless glob_pattern.is_a?(String) && !glob_pattern.strip.empty?

          context = { field_name: field, feature_name: feature_name, indent: "    " }
          validated = @glob_validator.validate_with_retry(glob_pattern, context)

          if validated != glob_pattern
            needs_update = true
            @stats_mutex.synchronize { @stats[:globs_fixed] += 1 }
          end

          validated
        end

        before_uniq = frontmatter[field].size
        frontmatter[field].uniq!
        needs_update = true if frontmatter[field].size < before_uniq
      end

      if needs_update
        puts "  Updating spec file with corrected globs..."
        yaml_front = YAML.dump(frontmatter)

        # Preserve keywords as inline JSON (matches original behaviour)
        if frontmatter['keywords']&.any?
          yaml_front.sub!(/^keywords:\s*\n(?:- .+\n)+/) do
            "keywords: #{frontmatter['keywords'].to_json}\n"
          end
        end

        updated_content = content.sub(/^---\n.*?\n---\n/m, "#{yaml_front}---\n")
        File.write(spec_path, updated_content)
        puts "Globs validated and corrected"
      else
        puts "All globs valid"
      end
    end

    def validate_and_fix_body_globs(spec_path, feature_name)
      puts "  Validating KUF globs..."

      content = File.read(spec_path)

      yaml_match = content.match(/^---\n(.*?)\n---\n/m)
      unless yaml_match
        log "Warning: Could not parse YAML frontmatter in #{spec_path}"
        return
      end

      begin
        frontmatter = YAML.safe_load(yaml_match[1], permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
      rescue Psych::Exception => e
        puts "  Could not parse frontmatter for KUF glob validation: #{e.message}"
        return
      end

      # KUF child specs: global scan for all related_code_globs values, aggregate into kuf_paths.
      # Validation of kuf_paths runs separately via validate_and_fix_globs(['kuf_paths']).
      if frontmatter.key?('kuf_paths')
        all_globs = content.scan(/\| `related_code_globs` \| (.+?) \|/).flat_map do |match|
          match[0].strip.delete('`').split(/;\s*/).map(&:strip).reject(&:empty?)
        end.uniq

        frontmatter['kuf_paths'] = all_globs
        yaml_front       = YAML.dump(frontmatter)
        updated_content  = content.sub(/^---\n.*?\n---\n/m, "#{yaml_front}---\n")
        File.write(spec_path, updated_content)
        puts "  Aggregated #{all_globs.size} globs into kuf_paths"
        return
      end

      # Build the set of files declared at feature level
      feature_files = []
      %w[frontend_paths backend_paths].each do |field|
        next unless frontmatter[field].is_a?(Array)
        frontmatter[field].each { |glob| feature_files.concat(Dir.glob(File.join(@root, glob))) }
      end
      feature_files.uniq!

      kufs = parse_kuf_metadata_tables(content)

      if kufs.empty?
        puts "No KUF globs to validate"
        return
      end

      needs_update = false
      feature_globs_updated = false

      kufs.each do |kuf|
        puts "    Validating KUF: #{kuf[:flow_name]}"

        next if kuf[:related_code_globs].nil? || kuf[:related_code_globs].empty?

        original_globs = kuf[:related_code_globs].dup
        updated_globs  = []

        kuf[:related_code_globs].each do |glob_pattern|
          kuf_files        = Dir.glob(File.join(@root, glob_pattern))
          non_subset_files = kuf_files - feature_files

          context = {
            kuf:          kuf,
            frontmatter:  frontmatter,
            feature_name: feature_name,
            spec_path:    spec_path,
            indent:       "      "
          }

          if non_subset_files.any?
            puts "References files outside feature globs"
            puts "      Asking LLM: are KUF globs correct, or should feature-level globs expand?"
            decision = kuf_glob_decision(glob_pattern, non_subset_files, frontmatter, kuf, spec_path, feature_name)

            if decision[:kuf_globs_correct]
              puts "    LLM decision: KUF globs correct — expanding feature-level globs"
              update_feature_globs_with_files(frontmatter, non_subset_files)

              # Refresh feature_files after expanding
              feature_files = []
              %w[frontend_paths backend_paths].each do |field|
                next unless frontmatter[field].is_a?(Array)
                frontmatter[field].each { |g| feature_files.concat(Dir.glob(File.join(@root, g))) }
              end
              feature_files.uniq!

              feature_globs_updated = true
              updated_globs << glob_pattern
            else
              puts "LLM decision: KUF globs incorrect — fixing"
              corrected, _ = request_glob_fix(glob_pattern, context, "LLM determined glob is incorrect")
              updated_globs << corrected
              if corrected != glob_pattern
                needs_update = true
                @stats_mutex.synchronize { @stats[:body_globs_fixed] += 1 }
              end
            end

          elsif kuf_files.empty?
            puts "No matches for: #{glob_pattern}"
            corrected, _ = request_glob_fix(glob_pattern, context, "No files matched this pattern")
            validated    = @glob_validator.validate_with_retry(corrected, context)
            updated_globs << validated
            if validated != glob_pattern
              needs_update = true
              @stats_mutex.synchronize { @stats[:body_globs_fixed] += 1 }
            end

          else
            validated = @glob_validator.validate_with_retry(glob_pattern, context)
            updated_globs << validated
            if validated != glob_pattern
              needs_update = true
              @stats_mutex.synchronize { @stats[:body_globs_fixed] += 1 }
            end
          end
        end

        if updated_globs != original_globs
          kuf[:related_code_globs] = updated_globs
          needs_update = true
        end
      end

      if needs_update || feature_globs_updated
        puts "  Updating spec file with corrected KUF globs..."
        update_spec_with_kufs(spec_path, frontmatter, kufs, feature_globs_updated)
        puts "KUF globs validated and corrected"
      else
        puts "All KUF globs valid"
      end
    end

    # Parse KUF flow sections from the spec body — returns array of KUF hashes.
    # Each hash: { section_num:, flow_name:, related_code_globs:, gherkin: }
    def parse_kuf_metadata_tables(content)
      kufs = []

      flow_sections = content.scan(/^### (1\.\d+) (.+?)\n\n\*\*Metadata:\*\*\n\n(\|.+?\|.+?\n)+/m)

      flow_sections.each do |section_num, flow_name, table_content|
        # Odd-numbered 1.x sections are flows (1.1, 1.3, ...); even are flow diagrams (1.2, 1.4, ...)
        next if section_num.split('.')[1].to_i.even?

        globs = []
        table_content.scan(/\| `related_code_globs` \| (.+?) \|/) do |match|
          glob_text = match[0].strip
          globs = glob_text.split(/[,;]\s*|\n/).map(&:strip).reject(&:empty?)
        end

        gherkin_match = content.match(/^### #{Regexp.escape(section_num)} .+?```gherkin\n(.+?)\n```/m)
        gherkin = gherkin_match ? gherkin_match[1].strip : ""

        kufs << {
          section_num:        section_num,
          flow_name:          flow_name.strip,
          related_code_globs: globs,
          gherkin:            gherkin
        }
      end

      kufs
    end

    # Ask the LLM whether a KUF glob that matches files outside the feature's declared paths
    # is correct (feature paths need to expand) or incorrect (KUF glob needs fixing).
    def kuf_glob_decision(glob_pattern, non_subset_files, frontmatter, kuf, spec_path, feature_name)
      prompt = <<~PROMPT
        SYSTEM INSTRUCTIONS:
        - Role: validator
        - Output Format: json
        - Automation Mode: true (no questions, no explanations outside deliverable)

        OUTPUT REQUIREMENTS:
        - Return ONLY a JSON object with the schema below
        - Use code block with ```json language tag (optional)
        - Include both fields: kuf_globs_correct (boolean) and reasoning (string)

        OUTPUT SCHEMA:
        ```json
        {
          "kuf_globs_correct": true,
          "reasoning": "brief explanation"
        }
        ```

        TASK:
        Determine if KUF globs are correct or if they reference unrelated files.

        Feature: #{feature_name}
        Key User Flow: "#{kuf[:flow_name]}"

        KUF glob: #{glob_pattern}
        Files matched OUTSIDE feature-level globs:
        #{non_subset_files.map { |f| "  - #{f.sub("#{@root}/", '')}" }.join("\n")}

        Current feature-level globs:
        - frontend_paths: #{frontmatter['frontend_paths'].to_json}
        - backend_paths: #{frontmatter['backend_paths'].to_json}


        Flow Gherkin steps:
        #{kuf[:gherkin]}

        Decision: Are the KUF globs correct (we missed files at the feature level)?
        Or are the KUF globs wrong (referencing unrelated files)?
      PROMPT

      response = call_llm(prompt)

      json_match = response.match(/```json\s*(\{.*?\})\s*```/m) || response.match(/(\{.*?\})/m)

      if json_match
        JSON.parse(json_match[1], symbolize_names: true)
      else
        log "Warning: Could not parse KUF decision JSON, defaulting to incorrect"
        { kuf_globs_correct: false, reasoning: "Failed to parse LLM response" }
      end
    rescue JSON::ParserError => e
      log "Error parsing KUF decision JSON: #{e.message}"
      { kuf_globs_correct: false, reasoning: "JSON parse error" }
    end

    # Add files that are outside the current feature paths into the appropriate path arrays.
    def update_feature_globs_with_files(frontmatter, files)
      files.each do |file|
        rel_path = file.sub("#{@root}/", '')

        if rel_path.start_with?('app/javascript/')
          parts        = rel_path.split('/')
          frontend_dir = parts[0..2].join('/')
          glob         = "#{frontend_dir}/**/*"
          frontmatter['frontend_paths'] ||= []
          frontmatter['frontend_paths'] << glob unless frontmatter['frontend_paths'].include?(glob)
        else
          frontmatter['backend_paths'] ||= []
          frontmatter['backend_paths'] << rel_path unless frontmatter['backend_paths'].include?(rel_path)
        end
      end
    end

    # Write corrected KUF globs (and optionally updated frontmatter) back into the spec file.
    def update_spec_with_kufs(spec_path, frontmatter, kufs, update_frontmatter)
      content = File.read(spec_path)

      if update_frontmatter
        yaml_front = YAML.dump(frontmatter)
        if frontmatter['keywords']&.any?
          yaml_front.sub!(/^keywords:\s*\n(?:- .+\n)+/) do
            "keywords: #{frontmatter['keywords'].to_json}\n"
          end
        end
        content.sub!(/^---\n.*?\n---\n/m, "#{yaml_front}---\n")
      end

      kufs.each do |kuf|
        next if kuf[:related_code_globs].nil? || kuf[:related_code_globs].empty?

        table_pattern = /^### #{Regexp.escape(kuf[:section_num])} .+?\n\n\*\*Metadata:\*\*\n\n(\|.+?\n)+/m

        content.sub!(table_pattern) do |match|
          match.sub(/\| `related_code_globs` \| .+? \|/) do
            globs_text = kuf[:related_code_globs].join('; ')
            "| `related_code_globs` | #{globs_text} |"
          end
        end
      end

      File.write(spec_path, content)
    end

    # Delegator so process methods can call request_glob_fix directly.
    def request_glob_fix(failed_glob, context, error_message)
      @glob_validator.request_glob_fix(failed_glob, context, error_message)
    end
  end
end

# Standalone CLI — only runs when invoked directly (not when required)
if __FILE__ == $0
  require 'optparse'
  require 'fileutils'
  require 'tmpdir'
  require_relative "#{SCRIPT_DIR}/llm_client"

  options = { root: Dir.pwd, no_retry: false }

  OptionParser.new do |opts|
    opts.banner = "Usage: validate-globs.rb <glob_pattern> [options]"
    opts.on('--root=DIR',     'Root directory for glob resolution (default: cwd)')  { |v| options[:root]     = v }
    opts.on('--feature=NAME', 'Feature name (context for LLM fix prompt)')          { |v| options[:feature]  = v }
    opts.on('--field=NAME',   'Field name (context for LLM fix prompt)')            { |v| options[:field]    = v }
    opts.on('--no-retry',     'Validate only — do not call LLM on failure')         { options[:no_retry] = true }
    opts.on('-h', '--help',   'Show this help') { puts opts; exit 0 }
  end.parse!

  if ARGV.empty?
    $stderr.puts "Error: glob_pattern argument required"
    $stderr.puts "Usage: validate-globs.rb <glob_pattern> [options]"
    exit 1
  end

  pattern  = ARGV[0]
  root_dir = File.expand_path(options[:root])

  # Reject brace expansion immediately — not supported in Ruby Dir.glob
  if pattern.include?('{') && pattern.include?(',')
    puts "ERROR: Brace expansion not supported in Ruby Dir.glob: #{pattern}"
    puts "Use separate patterns or wildcards instead."
    exit 1
  end

  matches = Dir.glob(File.join(root_dir, pattern))

  if matches.any?
    puts "VALID: #{matches.size} matches for: #{pattern}"
    exit 0
  end

  if options[:no_retry]
    puts "NO_MATCHES: #{pattern}"
    exit 1
  end

  # LLM retry
  puts "No matches for: #{pattern}"
  puts "Requesting LLM fix (up to #{SemanticSpecs::Validators::GlobValidator::MAX_ATTEMPTS - 1} attempt(s))..."

  workspace = Dir.mktmpdir('validate-globs-')
  begin
    llm       = SemanticSpecs::LlmClient.new(root_dir: root_dir, workspace_dir: workspace)
    validator = SemanticSpecs::Validators::GlobValidator.new(root_dir: root_dir, llm_client: llm)

    context = {
      feature_name: options[:feature] || 'unknown',
      field_name:   options[:field]   || 'unknown',
      indent:       ""
    }

    result = validator.validate_with_retry(pattern, context)

    if result != pattern
      puts "FIXED: #{result}"
      exit 0
    else
      puts "NO_MATCHES_AFTER_RETRY: #{result}"
      exit 1
    end
  ensure
    FileUtils.rm_rf(workspace)
  end
end
