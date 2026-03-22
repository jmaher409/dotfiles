# frozen_string_literal: true

module SemanticSpecs
  # All three spec generation paths (single-phase, two-phase, child spec),
  # plus the LLM response pruning and analysis parsing utilities they depend on.
  module SpecProcessor
    private

    # ---- Dispatcher ----

    def process_spec(config, resolved_target = nil)
      output_path = resolve_output_path(config, resolved_target)
      tmpl_path   = resolve_template(config['template'])

      if skip_existing && File.exist?(output_path)
        puts "  Skipping (exists): #{output_path.sub("#{@repo_root}/", '')}"
        return
      end

      # Child spec dispatch (e.g. leasing.kuf.spec.md)
      if config['_child_type']
        spec_prompt = config['prompt'] ? resolve_prompt(config['prompt']) : nil
        abort_with "No 'prompt' defined for child spec '#{config['_parent_key']}#{config['_item_name']}.#{config['_child_type']}' in semantic-specs.yml" unless spec_prompt

        mode = determine_mode(output_path)
        puts "  Mode: #{mode} (child-spec:#{config['_child_type']})"
        puts "  Output: #{output_path.sub("#{@repo_root}/", '')}"
        puts "  Prompt: #{display_paths(spec_prompt)}"
        puts "  Template: #{display_path(tmpl_path)}"

        if mode == :regenerate && File.exist?(output_path)
          File.delete(output_path)
          puts "  Deleted: #{output_path}"
        end
        FileUtils.mkdir_p(File.dirname(output_path))
        existing_created = mode == :update ? read_spec_frontmatter(output_path)&.fetch('created', nil) : nil

        process_child_spec(config, spec_prompt, tmpl_path, output_path, mode)

        if config['body_kuf_tables']
          validate_and_fix_body_globs(output_path, config['_item_name'])
          glob_fields = config['frontmatter_glob_fields'] || ['kuf_paths']
          validate_and_fix_globs(output_path, config['_item_name'], glob_fields)
        elsif config['frontmatter_glob_fields']
          validate_and_fix_globs(output_path, config['_item_name'], config['frontmatter_glob_fields'])
        end

        patch_frontmatter_field(output_path, 'created', existing_created || @now)
        patch_frontmatter_field(output_path, 'updated', @now)
        patch_frontmatter_field(output_path, 'model', @model || 'default')
        patch_owner_in_spec(output_path, config['_owner']) if config['_owner']

        @stats_mutex.synchronize { @stats[:specs_generated] += 1; @stats[:child_specs_generated] += 1 }
        puts "Child spec complete: #{output_path.sub("#{@repo_root}/", '')}"
        return
      end

      two_phase       = config.key?('analysis_prompt')
      spec_prompt     = config['prompt'] ? resolve_prompt(config['prompt']) : nil
      analysis_prompt = two_phase ? resolve_prompt(config['analysis_prompt']) : nil

      abort_with "No 'prompt' defined for target '#{target}' in semantic-specs.yml" unless spec_prompt

      if config['entry_point_base']
        entry_dir = File.join(@root, config['entry_point_base'], config['_item_name'])
        unless Dir.exist?(entry_dir)
          abort_with "Entry directory does not exist: #{entry_dir.sub("#{@repo_root}/", '')}\n" \
                     "  Target '#{target}' requires a directory at that path.\n" \
                     "  Check your --target argument — is this a pack or gem instead?"
        end
      end

      mode = determine_mode(output_path)
      puts "  Mode: #{mode} (#{two_phase ? 'analysis+spec' : 'spec'})"
      puts "  Output: #{output_path.sub("#{@repo_root}/", '')}"
      puts "  Analysis prompt: #{display_paths(analysis_prompt)}" if analysis_prompt
      puts "  Prompt: #{display_paths(spec_prompt)}"
      puts "  Template: #{display_path(tmpl_path)}"

      if mode == :regenerate && File.exist?(output_path)
        File.delete(output_path)
        puts "  Deleted existing spec for regeneration"
      end
      FileUtils.mkdir_p(File.dirname(output_path))
      existing_created = mode == :update ? read_spec_frontmatter(output_path)&.fetch('created', nil) : nil

      if two_phase
        process_two_phase(config, analysis_prompt, spec_prompt, tmpl_path, output_path, mode, resolved_target)
      else
        process_single_phase(config, spec_prompt, tmpl_path, output_path, mode)
      end

      validate_and_fix_globs(output_path, config['_item_name']) if config.key?('analysis_prompt') && config.key?('backing_dirs')

      patch_frontmatter_field(output_path, 'created', existing_created || @now)
      patch_frontmatter_field(output_path, 'updated', @now)

      owner = nil
      if two_phase && config['entry_point_base']
        team_names = load_team_names
        if team_names&.any?
          puts "  Resolving team ownership..."
          fm_content = File.read(output_path)
          yaml_match = fm_content.match(/^---\n(.*?)\n---\n/m)
          fm         = yaml_match ? YAML.safe_load(yaml_match[1], permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true) : {}
          owner      = resolve_owner_team(team_names, config['_item_name'], fm || {})
          patch_owner_in_spec(output_path, owner) if owner
        end
      end

      cascade_child_specs(config, owner) if two_phase
      @stats_mutex.synchronize { @stats[:specs_generated] += 1 }
      puts "Spec complete: #{output_path.sub("#{@repo_root}/", '')}"
    end

    # ---- Two-phase processing ----

    def process_two_phase(config, analysis_prompt_paths, spec_prompt_paths, tmpl_path, output_path, mode, resolved_target = nil)
      item_name    = config['_item_name']
      display_name = item_name.split('_').map(&:capitalize).join(' ')
      spec_rel     = resolved_target || target
      analysis_dir  = File.join(@root, 'tmp', 'semanticsearch', spec_rel)
      analysis_path = File.join(analysis_dir, 'ANALYSIS.md')

      # Determine entry dirs for Call 1
      entry_dirs = if config['entry_point_base']
        [File.join(@root, config['entry_point_base'], item_name)]
      else
        []
      end

      # Call 1: analyze or reuse
      _, domain_nouns = if File.exist?(analysis_path) && mode != :regenerate
        age_seconds = Time.now - File.mtime(analysis_path)
        age_hours   = (age_seconds / 3600.0).round(1)
        if age_seconds > 3600
          puts "  WARNING: Using cached analysis that is #{age_hours}h old — run with --force to refresh"
        else
          puts "  Using existing analysis from #{analysis_path.sub("#{@repo_root}/", '')}"
        end
        parse_analysis(File.read(analysis_path))
      else
        if mode == :regenerate && File.exist?(analysis_path)
          File.delete(analysis_path)
          puts "  Deleted existing analysis for regeneration"
        end
        dirs_display = entry_dirs.empty? ? '(no entry dirs)' : entry_dirs.map { |d| d.sub("#{@root}/", '') }.join(', ')
        puts "  Analyzing: #{dirs_display}"
        analyze_entry_point(entry_dirs, item_name, analysis_path, analysis_prompt_paths)
      end

      # Read full analysis for Call 2 context
      analysis_summary, _ = parse_analysis(File.read(analysis_path))
      analysis_full       = File.read(analysis_path)

      # Backing files fuzzy search (pure Ruby, no LLM) + LLM verification
      backing_candidates = []
      backing_content    = ""
      if config['backing_dirs'] || config['backend_search_dirs']
        backing_search_dirs = (config['backing_dirs'] || config['backend_search_dirs'] || []).map { |d| File.join(@root, d.chomp('/')) }
        puts "  Finding backing files..."
        raw_candidates = find_backend_files(domain_nouns, backing_search_dirs)
        log "  Found #{raw_candidates.size} backing candidates"
        puts "  Verifying backing file relevance..."
        backing_candidates = verify_links(item_name, analysis_summary, raw_candidates)
        log "  Confirmed #{backing_candidates.size} backing files"
        backing_content = collect_file_content(backing_candidates)
      end

      # Call 2: generate spec content sections
      puts "  Generating spec..."
      spec_prompt_content = spec_prompt_paths.map { |p| File.read(p) }.join("\n\n")
      update_context      = mode == :update ? existing_spec_context(output_path) : ""

      full_prompt  = spec_prompt_content
      full_prompt += "\n\n## Analysis\n\n#{analysis_full}" unless analysis_full.to_s.strip.empty?
      full_prompt += "\n\n## Backing Files\n\n#{backing_content}" unless backing_content.empty?
      full_prompt += update_context

      unless config['entry_point_base']
        integration_tmpl = File.join(SKILL_DIR, 'shared', 'templates', 'semantic-integration-spec-template.md')
        if File.exist?(integration_tmpl)
          config, tmpl_content = extract_spec_type_from_template(config, integration_tmpl)
          full_prompt += tmpl_content
        end

        guidelines = File.join(SKILL_DIR, 'prompts', 'semantic-spec-guidelines.md')
        full_prompt = "#{File.read(guidelines)}\n\n#{full_prompt}" if File.exist?(guidelines)
      end

      response = call_llm(full_prompt)

      if config['entry_point_base']
        # Feature specs: assemble programmatic frontmatter + heading + summary + LLM content sections
        frontmatter_yaml = build_feature_frontmatter(config, item_name, domain_nouns, backing_candidates)
        heading          = "# #{display_name}\n\n> **Feature Specification** | **Status**: ai-generated-draft\n\n## 1. Overview\n\n### 1.1 Feature Summary\n\n#{analysis_summary}\n\n"
        content_body     = prune_llm_preamble(response)

        # Inject Section 2 placeholder — updated by update_parent_section2 after KUF cascade
        kuf_link     = "## 2. Key User Flows\n\n_KUF flow files will be listed here after generation._\n\n"
        content_body = content_body.sub(/^(## 3\.)/, "#{kuf_link}\\1")

        File.write(output_path, "#{frontmatter_yaml}---\n\n#{heading}#{content_body}")
      else
        # Integration specs: LLM generates full spec including frontmatter
        File.write(output_path, prune_llm_preamble_with_frontmatter(response))
        patch_frontmatter_field(output_path, 'spec_type', config['_spec_type']) if config['_spec_type']
      end
    end

    # ---- Single-phase processing ----

    def process_single_phase(config, spec_prompt_paths, tmpl_path, output_path, mode)
      item_name        = config['_item_name']
      guidelines       = File.join(SKILL_DIR, 'prompts', 'semantic-spec-guidelines.md')
      spec_prompt_paths = [guidelines] + spec_prompt_paths if File.exist?(guidelines) && !spec_prompt_paths.include?(guidelines)
      prompt_content   = spec_prompt_paths.map { |p| File.read(p) }.join("\n\n")
      config, template_content = extract_spec_type_from_template(config, tmpl_path)
      update_context   = mode == :update ? existing_spec_context(output_path) : ""
      target_info      = build_target_info(config, item_name)

      full_prompt = prompt_content + template_content + target_info + update_context

      puts "  Generating spec..."
      response = call_llm(full_prompt)
      content  = prune_llm_preamble_with_frontmatter(response)
      File.write(output_path, content)
      patch_frontmatter_field(output_path, 'spec_type', config['_spec_type']) if config['_spec_type']
    end

    # ---- Child spec processing ----

    def process_child_spec(config, spec_prompt_paths, _tmpl_path, output_path, mode)
      item_name  = config['_item_name']
      child_type = config['_child_type']
      parent_key = config['_parent_key']

      # Reuse parent's ANALYSIS.md — child specs never run their own analysis call
      analysis_path = File.join(@root, 'tmp', 'semanticsearch', parent_key, item_name, 'ANALYSIS.md')
      unless File.exist?(analysis_path)
        abort_with "No analysis found for '#{item_name}'. Run the parent spec first: --target=#{parent_key}#{item_name}"
      end

      puts "  Using analysis from #{analysis_path.sub("#{@repo_root}/", '')}"
      analysis_full = File.read(analysis_path)

      parent_spec      = "#{item_name}.spec.md"
      parent_spec_path = File.join(@root, 'specifications', parent_key, item_name, parent_spec)
      parent_fm        = read_spec_frontmatter(parent_spec_path)

      flow_slug   = config['_flow_slug']
      flow_name   = config['_flow_name']
      spec_id     = if flow_slug
        "#{generate_spec_id(item_name)}-KUF-#{flow_slug.upcase.gsub('-', '_')}"
      else
        "#{generate_spec_id(item_name)}-#{child_type.upcase}"
      end

      target_info_lines = [
        "\n\n## Target Information",
        "",
        "- **Item name:** #{item_name}",
        "- **Semantic Spec ID:** #{spec_id}",
        "- **Parent spec:** #{parent_spec}",
        "- **{repo}:** #{@repo}",
        "- **{now}:** #{@now}"
      ]
      if flow_slug
        target_info_lines << "- **Flow name:** #{flow_name}"
        target_info_lines << "- **Flow slug:** #{flow_slug}"
      end
      if parent_fm
        target_info_lines << ""
        target_info_lines << "Parent spec verified paths (use these as grounding for glob patterns — do not invent pack or directory names):"
        target_info_lines << "- **packs:** #{parent_fm['packs'].to_json}" if parent_fm['packs']&.any?
        target_info_lines << "- **frontend_paths:** #{parent_fm['frontend_paths'].to_json}" if parent_fm['frontend_paths']&.any?
        target_info_lines << "- **backend_paths:** #{parent_fm['backend_paths'].to_json}" if parent_fm['backend_paths']&.any?
      end
      target_info = target_info_lines.join("\n")

      guidelines          = File.join(SKILL_DIR, 'prompts', 'semantic-spec-guidelines.md')
      spec_prompt_paths   = [guidelines] + spec_prompt_paths if File.exist?(guidelines) && !spec_prompt_paths.include?(guidelines)
      spec_prompt_content = spec_prompt_paths.map { |p| File.read(p) }.join("\n\n")
      update_context      = mode == :update ? existing_spec_context(output_path) : ""

      full_prompt  = spec_prompt_content
      full_prompt += "\n\n## Analysis\n\n#{analysis_full}"
      full_prompt += target_info
      full_prompt += update_context

      puts "  Generating child spec (#{child_type})..."
      response = call_llm(full_prompt)
      content  = prune_llm_preamble_with_frontmatter(response)
      File.write(output_path, content)
    end

    def extract_spec_type_from_template(config, tmpl_path)
      return [config, ""] unless tmpl_path

      tmpl_raw      = File.read(tmpl_path)
      spec_type_val = nil

      if tmpl_raw =~ /\A---\n(.*?)\n---\n/m
        begin
          fm = YAML.safe_load($1, permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
          spec_type_val = fm['spec_type'] if fm.is_a?(Hash) && fm['spec_type']
        rescue Psych::Exception
          # ignore parse errors
        end
      end

      if spec_type_val
        tmpl_raw = tmpl_raw.sub(/^(spec_type:\s*)["']?#{Regexp.escape(spec_type_val)}["']?(\s*\n)/, "\\1\"{spec_type}\"\\2")
        config    = config.merge('_spec_type' => spec_type_val)
      end

      [config, "\n\n## Template\n\n#{tmpl_raw}"]
    end

    def build_target_info(config, item_name)
      lines = [
        "\n\n## Target Information",
        "",
        "- **Item name:** #{item_name}",
        "- **Semantic Spec ID:** #{generate_spec_id(item_name)}",
        "- **{repo}:** #{@repo}",
        "- **{model}:** #{@model || 'default'}",
        "- **{now}:** #{@now}"
      ]

      if config['entry_point_base']
        item_dir = File.join(@root, config['entry_point_base'], item_name).sub("#{@repo_root}/", '')
        lines << "- **{dir}:** #{item_dir}"
      end

      lines << "- **{app_path}:** #{@root.sub("#{@repo_root}/", '')}" if @root != @repo_root
      lines << "- **{app_name}:** #{config['_app_name']}"  if config['_app_name']
      lines << "- **{spec_type}:** #{config['_spec_type']}" if config['_spec_type']

      if config['source_dirs']
        lines << "- **Source directories:**"
        config['source_dirs'].each { |d| lines << "  - #{d}" }
      end

      lines.join("\n")
    end

    def analyze_entry_point(entry_dirs, item_name, analysis_path, prompt_paths)
      display_name = item_name.split('_').map(&:capitalize).join(' ')
      analysis_prompt_content = prompt_paths.map { |p| File.read(p) }.join("\n\n")

      entry_dirs.each do |d|
        puts "    Entry dir: #{d} (exists: #{Dir.exist?(d)})"
      end

      full_prompt = analysis_prompt_content
      unless entry_dirs.empty?
        dir_list = entry_dirs.map { |d| "- #{d.sub("#{@root}/", '')}" }.join("\n")
        full_prompt += "\n\n## Entry Point\n\nItem: #{item_name}\nDisplay name: #{display_name}\nDirectories:\n#{dir_list}"
      end

      response = call_llm(full_prompt)
      FileUtils.mkdir_p(File.dirname(analysis_path))
      File.write(analysis_path, prune_llm_preamble(response))
      puts "  Analysis: #{analysis_path.sub("#{@repo_root}/", '')}"
      @stats_mutex.synchronize { @stats[:analysis_files_generated] += 1 }
      parse_analysis(response)
    end

    def existing_spec_context(spec_path)
      return "" unless File.exist?(spec_path)
      content = File.read(spec_path)
      <<~CONTEXT

        ## Existing Spec (Update Mode)

        The following is the existing specification for this target. You are updating it to reflect
        the current state of the code. Preserve manually edited content where possible. Update
        sections that are outdated or incomplete based on your analysis of the source files.

        ```
        #{content}
        ```
      CONTEXT
    end

    # ---- LLM response pruning ----

    def prune_llm_preamble(content)
      if content =~ /^[#]{2,3} /m
        content[content.index($&)..-1]
      else
        content
      end
    end

    def prune_llm_preamble_with_frontmatter(content)
      # Step 1: Strip entire-output code fence wrapping (``` or ```yaml or ```markdown)
      content = content.sub(/\A\s*```[a-zA-Z]*\n(.*)\n```\s*\z/m, '\1')

      # Step 2: Locate YAML frontmatter — find first ---\n, then closing ---\n
      fm_open = content.index(/^---\n/)

      if fm_open
        fm_body_start = fm_open + 4
        fm_close      = content.index(/^---\n/, fm_body_start)

        if fm_close
          fm_block = content[fm_open..fm_close + 3]   # "---\n[yaml]\n---\n"
          after_fm = content[fm_close + 4..]           # everything after closing ---\n

          # Step 3: Strip stray artifacts between frontmatter and body:
          # orphan ``` lines (LLM closing a code fence it opened), then leading blank lines
          body = after_fm
          body = body.sub(/\A(\s*```[^\n]*\n)+/, '')
          body = body.sub(/\A\n+/, '')

          return "#{fm_block}\n#{strip_trailing_noise(body)}"
        end
      end

      # Fallback: no frontmatter — find first heading
      if content =~ /^[#]{1,3} /m
        return strip_trailing_noise(content[content.index($&)..])
      end

      # Last resort: return as-is with trailing noise stripped
      strip_trailing_noise(content)
    end

    def strip_trailing_noise(content)
      # Strip trailing code fence only if it is an unmatched outer wrapping fence
      # (odd number of fences = one extra at the end = LLM wrapping artifact).
      # Even number = all fences are content fences — do not strip.
      fence_count = content.scan(/^```/).size
      result = fence_count.odd? ? content.sub(/\n```\s*\z/, "\n") : content

      # Strip trailing conversational prose (paragraphs ending with ?)
      # Specs never end with ?; conversational LLM output often does.
      lines     = result.lines
      check_from = [0, lines.length - 10].max
      last_q    = lines[check_from..].rindex { |l| l.strip.end_with?('?') }
      if last_q
        last_q    += check_from
        para_start = last_q
        para_start -= 1 while para_start > 0 && !lines[para_start - 1].strip.empty?
        result = lines[0...para_start].join.rstrip + "\n"
      end

      result
    end

    def prune_llm_preamble_simple(content)
      # Simpler pruning for single-line responses (like glob fixes)
      if content =~ /GLOB:\s*(.+?)$/m
        return $1.strip
      end

      if content.include?("Starting Claude Code...")
        start_pos = content.index("Starting Claude Code...")
        after_marker = content[(start_pos + "Starting Claude Code...".length)..-1]
        cleaned = after_marker.sub(/\A[^\n]*\n/, '').strip

        if cleaned =~ /GLOB:\s*(.+?)$/m
          return $1.strip
        end

        cleaned.lines.map(&:strip).reject(&:empty?).find do |line|
          line.include?('/') && !line.match?(/^(Here|The|I|Let|Based|This|Looking|From)/)
        end || cleaned.lines.map(&:strip).reject(&:empty?).last || cleaned.lines.map(&:strip).reject(&:empty?).first
      else
        content.strip
      end
    end

    # ---- Analysis parsing ----

    def format_duration(seconds)
      if seconds < 60
        "#{seconds.round(2)}s"
      else
        minutes = (seconds / 60).floor
        secs = (seconds % 60).round(2)
        "#{minutes}m #{secs}s"
      end
    end

    def parse_analysis(content)
      # Extract summary (text between ## ... Feature Summary and ## Domain Nouns)
      summary_match = content.match(/## .*Feature Summary\s*\n(.*?)\n## Domain Nouns/m)
      summary = summary_match ? summary_match[1].strip : ""

      # Extract domain nouns (list items after ## Domain Nouns)
      nouns = []
      if content.match(/## Domain Nouns\s*\n(.*?)(?=\n##|\z)/m)
        nouns_text = Regexp.last_match(1)
        raw_items = nouns_text.scan(/^[-*]\s*(.+)$/).flatten.map(&:strip)

        raw_items.each do |item|
          # Remove description in parentheses
          noun_part = item.gsub(/\s*\([^)]+\)\s*$/, '').strip

          # Check if it's comma-separated (generic fallback terms)
          if noun_part.include?(',')
            noun_part.split(',').each { |term| nouns << term.strip }
          else
            nouns << noun_part
          end
        end
      end

      [summary, nouns.uniq]
    end
  end
end
