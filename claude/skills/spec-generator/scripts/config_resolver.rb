# frozen_string_literal: true

module SemanticSpecs
  # Config loading, scope resolution, target matching, and output path calculation.
  module ConfigResolver
    private

    def find_config_file
      dir = Dir.pwd
      loop do
        candidate = File.join(dir, 'semantic-specs.yml')
        return candidate if File.exist?(candidate)
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end
      nil
    end

    def resolve_scope_root
      if scope_name
        scopes = @config['scopes'] || {}
        scope  = scopes[scope_name]
        abort_with "Scope '#{scope_name}' not found in semantic-specs.yml" unless scope
        File.expand_path(scope['root'], @repo_root)
      else
        @repo_root
      end
    end

    def scope_spec_paths
      if scope_name
        scopes = @config['scopes'] || {}
        scope  = scopes[scope_name] || {}
        scope['spec_paths'] || {}
      else
        @config['spec_paths'] || {}
      end
    end

    def resolve_spec_config(target_name)
      paths = scope_spec_paths

      # Path prefix match: target=javascript/invoice_list matches key javascript/
      paths.each do |key, config|
        next unless key.end_with?('/') && target_name.start_with?(key)

        item_name = target_name[key.length..]

        # Child spec detection: item_name contains a dot (e.g. "leasing.kuf" or "leasing.prospect-inquiry.kuf").
        # Construct child key like "javascript.kuf/" and look it up.
        if item_name.include?('.')
          dot_idx    = item_name.rindex('.')
          base_item  = item_name[0...dot_idx]   # "leasing" or "leasing.prospect-inquiry"
          child_type = item_name[dot_idx + 1..] # "kuf"
          child_key  = "#{key.chomp('/')}.#{child_type}/" # "javascript.kuf/"

          if paths.key?(child_key)
            # Per-flow KUF: base_item may be "leasing.prospect-inquiry" — split into item + flow slug
            flow_slug = nil
            if base_item.include?('.')
              slug_idx   = base_item.index('.')
              flow_slug  = base_item[slug_idx + 1..] # "prospect-inquiry"
              base_item  = base_item[0...slug_idx]   # "leasing"
            end

            merged = paths[child_key].merge(
              '_item_name'  => base_item,
              '_child_type' => child_type,
              '_key'        => child_key,
              '_parent_key' => key
            )
            merged['_flow_slug'] = flow_slug if flow_slug
            return merged
          end
        end

        return config.merge('_item_name' => item_name, '_key' => key)
      end

      # Exact flat name match: target=foliospace_integration matches key foliospace_integration
      if paths.key?(target_name)
        return paths[target_name].merge('_item_name' => target_name, '_key' => target_name)
      end

      nil
    end

    def derive_repo
      stdout, _stderr, status = Open3.capture3('git', 'remote', 'get-url', 'origin', chdir: @repo_root)
      return 'unknown/unknown' unless status.success?

      url = stdout.strip
      # SSH: git@github.com:org/repo.git  or  HTTPS: https://github.com/org/repo.git
      if url =~ /github\.com[:\/](.+?)(?:\.git)?$/
        $1
      else
        'unknown/unknown'
      end
    end

    def resolve_output_path(config, resolved_target = nil)
      if config['output']
        File.expand_path(config['output'], @root)
      elsif config['_child_type']
        item_name  = config['_item_name']
        child_type = config['_child_type']
        parent_key = config['_parent_key']
        flow_slug  = config['_flow_slug']
        spec_rel   = "#{parent_key}#{item_name}" # e.g. "javascript/leasing"
        filename   = flow_slug ? "#{item_name}.#{flow_slug}.#{child_type}.spec.md"
                               : "#{item_name}.#{child_type}.spec.md"
        File.join(@root, 'specifications', spec_rel, filename)
      else
        item_name = config['_item_name']
        spec_rel  = resolved_target || target
        File.join(@root, 'specifications', spec_rel, "#{item_name}.spec.md")
      end
    end

    def resolve_prompt(prompt_val)
      abort_with "Prompt value is nil" unless prompt_val

      directive = File.join(SKILL_DIR, 'prompts', 'headless-directive.md')

      paths = Array(prompt_val).map do |val|
        if val.include?('/')
          path = File.expand_path(val, @repo_root)
          abort_with "Prompt file not found: #{path}" unless File.exist?(path)
          path
        else
          path = File.join(SKILL_DIR, 'prompts', "#{val}.md")
          abort_with "Built-in prompt not found: #{path}" unless File.exist?(path)
          path
        end
      end

      File.exist?(directive) && !paths.include?(directive) ? paths.unshift(directive) : paths
    end

    def resolve_template(template_val)
      return nil unless template_val
      if template_val.include?('/')
        path = File.expand_path(template_val, @repo_root)
        abort_with "Template file not found: #{path}" unless File.exist?(path)
        path
      else
        path = File.join(SKILL_DIR, 'shared', 'templates', "#{template_val}.md")
        abort_with "Built-in template not found: #{path}" unless File.exist?(path)
        path
      end
    end

    def build_app_index_config
      resolved_app_name = @app_name || @scope_name || File.basename(@root)
      resolved_app_path = @app_path || @root.sub("#{@repo_root}/", '')

      {
        '_item_name' => 'app_index',
        '_key'       => 'app_index',
        '_app_name'  => resolved_app_name,
        '_app_path'  => resolved_app_path,
        'output'     => 'specifications/app_index.spec.md',
        'prompt'     => 'semantic-app-index-prompt',
        'template'   => 'semantic-app-index-template'
      }
    end

    def display_path(abs_path)
      return '(none)' unless abs_path
      if abs_path.start_with?(@repo_root)
        abs_path.sub("#{@repo_root}/", '')
      elsif abs_path.start_with?(SKILL_DIR)
        "(built-in) #{File.basename(abs_path, '.md')}"
      else
        abs_path
      end
    end

    def display_paths(paths)
      arr = Array(paths).map { |p| display_path(p) }
      return arr.first if arr.size == 1
      "\n" + arr.map { |p| "    #{p}" }.join("\n")
    end

    def ensure_specs_dir(path)
      FileUtils.mkdir_p(File.dirname(path))
    end
  end
end
