# frozen_string_literal: true

require 'json'
require 'timeout'
require 'open3'
require 'fileutils'

module SemanticSpecs
  class LlmClient
    LLM_TIMEOUT_SECONDS = 1800

    attr_reader :workspace_dir, :root_dir, :verbose, :model

    def initialize(root_dir:, workspace_dir:, verbose: false, model: nil)
      @root_dir = root_dir
      @workspace_dir = workspace_dir
      @verbose = verbose
      @model = model
      FileUtils.mkdir_p(workspace_dir)
    end

    def call(prompt)
      prompt_file = save_prompt(prompt)
      log "Calling LLM: #{prompt_file}"

      start_time = Time.now
      puts "    Starting LLM call (30 min timeout)..."

      response_json = execute_with_timeout(prompt_file)
      duration = Time.now - start_time

      puts "    Completed in #{format_duration(duration)}"

      usage = response_json['usage'] || {}
      {
        response:                    response_json['result'],
        duration:                    duration,
        cost_usd:                    response_json['total_cost_usd'] || 0,
        input_tokens:                usage['input_tokens'] || 0,
        output_tokens:               usage['output_tokens'] || 0,
        cache_creation_input_tokens: usage['cache_creation_input_tokens'] || 0,
        cache_read_input_tokens:     usage['cache_read_input_tokens'] || 0,
        num_turns:                   response_json['num_turns'] || 0
      }
    end

    private

    def save_prompt(prompt)
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S_%N")
      prompt_file = File.join(workspace_dir, "prompt_#{timestamp}.txt")
      File.write(prompt_file, prompt)
      prompt_file
    end

    def execute_with_timeout(prompt_file)
      puts "    LLM model: #{model || '(default)'}"
      puts "    LLM chdir: #{root_dir}"
      puts "    Ruby pwd:  #{Dir.pwd}"
      Timeout.timeout(LLM_TIMEOUT_SECONDS) do
        cmd = ['otto', 'agents', 'claude', '--short-session', '--skip-upgrade',
               '--', '--output-format', 'json']
        cmd.push('--model', model) if model
        cmd.push('-p', prompt_file)

        stdout, stderr, status = Open3.capture3(*cmd, chdir: root_dir)

        unless status.success?
          raise "LLM call failed (exit #{status.exitstatus}): #{stderr}\n#{stdout}"
        end

        parse_json_response(stdout)
      end
    rescue Timeout::Error
      raise "LLM call timed out after #{LLM_TIMEOUT_SECONDS / 60} minutes"
    end

    def parse_json_response(response_text)
      json_start = response_text.index('{')
      raise "LLM returned no JSON" unless json_start

      json_text = response_text[json_start..-1]
      JSON.parse(json_text)
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

    def log(message)
      puts message if verbose
    end
  end
end
