# frozen_string_literal: true

module SemanticSpecs
  # KUF flow discovery and child-spec cascade after two-phase spec generation.
  module KufCascade
    private

    # After generating a two-phase (feature) spec, automatically generate any registered
    # child specs (e.g. KUF) for the same item.
    #
    # Rules:
    #   - Child missing          → always generate (create)
    #   - Child exists + --force → delete and regenerate (handled by process_spec)
    #   - Child exists, no force → skip
    def cascade_child_specs(parent_config, owner = nil)
      parent_key = parent_config['_key']
      item_name  = parent_config['_item_name']

      scope_spec_paths.each do |child_key, child_entry|
        next unless child_entry.is_a?(Hash) && child_entry['parent'] == parent_key

        child_type = child_key.chomp('/').split('.').last
        base_config = child_entry.merge(
          '_item_name'  => item_name,
          '_child_type' => child_type,
          '_key'        => child_key,
          '_parent_key' => parent_key
        )
        base_config['_owner'] = owner if owner

        if child_type == 'kuf'
          # Per-flow KUF: discover flows from analysis, generate one file per flow
          puts "\n  Discovering KUF flows for #{item_name}..."
          flows = discover_kuf_flows(parent_config)

          if flows.empty?
            puts "  No flows discovered — updating Section 2 accordingly"
            update_parent_section2(parent_config, [])
            next
          end

          puts "  Found #{flows.size} flow(s): #{flows.map { |f| f[:slug] }.join(', ')}"

          flows.each do |flow|
            child_config = base_config.merge('_flow_slug' => flow[:slug], '_flow_name' => flow[:name])
            child_output = resolve_output_path(child_config)

            if File.exist?(child_output) && !force
              puts "  KUF flow '#{flow[:slug]}' exists — skipping (use --force to regenerate)"
              next
            end

            puts "\n  Cascading KUF flow: #{flow[:name]} (#{flow[:slug]})"
            process_spec(child_config)
          end

          update_parent_section2(parent_config, flows)
        else
          child_config = base_config
          child_output = resolve_output_path(child_config)

          if File.exist?(child_output) && !force
            puts "  Child spec (#{child_type}) exists — skipping (use --force to regenerate)"
            next
          end

          puts "\n  Cascading child spec: #{child_type}"
          process_spec(child_config)
        end
      end
    end

    def discover_kuf_flows(parent_config)
      parent_key    = parent_config['_key']
      item_name     = parent_config['_item_name']
      analysis_path = File.join(@root, 'tmp', 'semanticsearch', parent_key, item_name, 'ANALYSIS.md')

      unless File.exist?(analysis_path)
        puts "  Warning: No analysis found at #{analysis_path} — cannot discover KUF flows"
        return []
      end

      analysis = File.read(analysis_path)

      headless = File.join(SKILL_DIR, 'prompts', 'headless-directive.md')
      headless_content = File.exist?(headless) ? File.read(headless) : ""

      discovery_prompt = <<~PROMPT
        #{headless_content}

        Identify the Key User Flows (KUFs) for this feature from the analysis below.

        A KUF must meet BOTH criteria:
        1. Material Business Value: The flow delivers material, quantifiable business value to the customer.
        2. Business-Critical Impact: Any disruption to the flow causes a severe, business-critical impact (Major+ bug).

        Only include flows that meet both criteria. Secondary features, configuration flows, and supporting workflows that do not have severe business impact if disrupted are NOT KUFs.

        Output ONLY a JSON array — your response must begin with `[` and end with `]`.
        Each object must have exactly two keys:
        - "slug": kebab-case identifier (lowercase, hyphens, no spaces)
        - "name": human-readable flow name (title case)

        Example output: [{"slug":"prospect-inquiry","name":"Prospect Inquiry"},{"slug":"showing-coordination","name":"Showing Coordination"}]

        ## Analysis

        #{analysis}
      PROMPT

      puts "  Calling LLM to discover flows..."
      response = call_llm(discovery_prompt)

      json_str = response.strip

      flows = JSON.parse(json_str)
      flows.map { |f| { slug: f['slug'], name: f['name'] } }
    rescue JSON::ParserError => e
      puts "  Warning: Failed to parse flow discovery response: #{e.message}"
      puts "  Response was: #{response.to_s[0..200]}"
      []
    end

    def update_parent_section2(parent_config, flows)
      parent_key  = parent_config['_key']
      item_name   = parent_config['_item_name']
      parent_path = File.join(@root, 'specifications', parent_key, item_name, "#{item_name}.spec.md")

      unless File.exist?(parent_path)
        puts "  Warning: Parent spec not found at #{parent_path} — skipping Section 2 update"
        return
      end

      body = flows.empty? \
        ? "_No Key User Flows identified for this feature._" \
        : flows.map { |f| "- [#{f[:name]}](#{item_name}.#{f[:slug]}.kuf.spec.md)" }.join("\n")
      new_section2 = "## 2. Key User Flows\n\n#{body}\n\n"

      content = File.read(parent_path)
      if content =~ /^## 2\. Key User Flows\n.*?(?=^## 3\.)/m
        updated = content.sub(/^## 2\. Key User Flows\n.*?(?=^## 3\.)/m, new_section2)
      else
        # Section 2 not found — insert before Section 3
        updated = content.sub(/^(## 3\.)/, "#{new_section2}\\1")
      end

      File.write(parent_path, updated)
      puts "  Updated Section 2 manifest in #{parent_path.sub("#{@repo_root}/", '')}"
    end
  end
end
