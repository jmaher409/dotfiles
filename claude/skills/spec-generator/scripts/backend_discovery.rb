# frozen_string_literal: true

module SemanticSpecs
  # Backend file fuzzy search, LLM relevance verification, file content collection,
  # and team ownership resolution.
  module BackendDiscovery
    private

    def find_backend_files(domain_nouns, backend_search_dirs)
      return [] if domain_nouns.empty?

      candidates = []
      backend_search_dirs.each do |dir|
        next unless Dir.exist?(dir)
        domain_nouns.each do |noun|
          pattern = noun.downcase.gsub(/\s+/, '_')
          matches = Dir.glob("#{dir.chomp('/')}/**/*#{pattern}*.rb").select { |f| File.file?(f) }
          candidates.concat(matches)
        end
      end

      candidates.uniq.sort
    end

    def verify_links(feature_name, summary, candidates)
      return [] if candidates.empty?

      candidate_list = candidates.map { |f| "- #{f.sub("#{@root}/", '')}" }.join("\n")

      prompt = <<~PROMPT
        SYSTEM INSTRUCTIONS:
        - Role: validator
        - Output Format: json_array
        - Automation Mode: true (no questions, no explanations outside deliverable)

        OUTPUT REQUIREMENTS:
        - Return ONLY a JSON array of file paths
        - Use code block with ```json language tag
        - Include only highly relevant backend files for this frontend feature
        - Return empty array [] if no files are relevant

        OUTPUT SCHEMA:
        ```json
        ["path/to/file1.rb", "path/to/file2.rb"]
        ```

        TASK:
        Identify which backend files are related to the frontend feature.

        Frontend feature: #{feature_name}
        Feature summary: #{summary}

        Backend file candidates (from fuzzy search):
        #{candidate_list}

        Exclude files that are unrelated or only tangentially related.
      PROMPT

      response   = call_llm(prompt)
      json_match = response.match(/```json\s*(\[.*?\])\s*```/m) || response.match(/(\[.*?\])/m)

      if json_match
        paths = JSON.parse(json_match[1])
        paths.map { |p| File.join(@root, p) }
      else
        log "Warning: Could not parse JSON from verify_links response"
        []
      end
    rescue JSON::ParserError => e
      log "Error parsing verify_links JSON: #{e.message}"
      []
    end

    def collect_file_content(files)
      return "" if files.empty?
      files.map do |f|
        rel = f.sub("#{@root}/", '')
        begin
          "### #{rel}\n#{File.read(f)}"
        rescue => e
          "### #{rel}\n(Could not read: #{e.message})"
        end
      end.join("\n\n")
    end

    def load_team_names
      teams_dir = File.join(@root, 'config', 'teams')
      return nil unless Dir.exist?(teams_dir)

      Dir.entries(teams_dir)
         .select { |f| f.end_with?('.yml') }
         .map    { |f| f.sub(/\.yml$/, '') }
         .sort
    end

    def resolve_owner_team(team_names, item_name, frontmatter)
      packs          = Array(frontmatter['packs'])
      frontend_paths = Array(frontmatter['frontend_paths'])
      backend_paths  = Array(frontmatter['backend_paths'])
      files_context  = (frontend_paths + backend_paths + packs).uniq.first(30).map { |p| "- #{p}" }.join("\n")

      prompt = <<~PROMPT
        SYSTEM INSTRUCTIONS:
        - Role: team-ownership-resolver
        - Output Format: plain_string
        - Automation Mode: true (no questions, no meta-commentary)

        OUTPUT REQUIREMENTS:
        - Return ONLY the team name as a single plain string
        - Must be exactly one of the listed team names
        - No explanation, no markdown, no quotes

        TASK:
        Identify which team owns this feature based on its name and associated files.

        Feature: #{item_name}

        Associated files and packs:
        #{files_context.empty? ? '(none)' : files_context}

        Available team names (return exactly one):
        #{team_names.map { |t| "- #{t}" }.join("\n")}
      PROMPT

      response = call_llm(prompt).strip.lines.first&.strip.to_s
      team_names.find { |t| t.downcase == response.downcase } ||
        team_names.find { |t| response.downcase.include?(t.downcase) } ||
        response
    end
  end
end
