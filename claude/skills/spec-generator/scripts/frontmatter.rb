# frozen_string_literal: true

module SemanticSpecs
  # Frontmatter read/write/patch and path compression utilities.
  module Frontmatter
    PATH_DEPTH = 4

    private

    def read_spec_frontmatter(spec_path)
      return nil unless File.exist?(spec_path)
      content = File.read(spec_path)
      return nil unless content =~ /\A---\n(.*?)\n---\n/m
      YAML.safe_load($1, permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
    rescue Psych::Exception
      nil
    end

    def build_feature_frontmatter(config, item_name, domain_nouns, backing_candidates)
      display_name = item_name.split('_').map(&:capitalize).join(' ')

      frontend_paths = if config['entry_point_base']
        ["#{config['entry_point_base'].chomp('/')}/#{item_name}/**/*"]
      else
        []
      end

      backend_paths = compress_paths(backing_candidates.map { |f| f.sub("#{@root}/", '') })
      packs         = extract_packs(backing_candidates)

      frontmatter = {
        'description'      => "#{display_name} Semantic Specification",
        'tags'             => ['semantic-feature-spec'],
        'type'             => 'semantic-spec',
        'repo'             => @repo,
        'spec_type'        => 'feature',
        'semantic_spec_id' => generate_spec_id(item_name),
        'status'           => 'ai-generated-draft',
        'keywords'         => domain_nouns,
        'packs'            => packs,
        'frontend_paths'   => frontend_paths,
        'backend_paths'    => backend_paths,
        'created'          => @now,
        'updated'          => @now,
        'model'            => @model || 'default'
      }

      yaml = YAML.dump(frontmatter)

      if domain_nouns.any?
        yaml.sub!(/^keywords:\s*\n(?:- .+\n)+/) do
          "keywords: #{domain_nouns.to_json}\n"
        end
      end

      yaml
    end

    def patch_frontmatter_field(spec_path, field, value)
      content    = File.read(spec_path)
      yaml_match = content.match(/^---\n(.*?)\n---\n/m)
      return unless yaml_match

      begin
        frontmatter = YAML.safe_load(yaml_match[1], permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
      rescue Psych::Exception
        return
      end

      return unless frontmatter.is_a?(Hash)
      return if frontmatter[field] == value

      frontmatter[field] = value
      yaml_front = YAML.dump(frontmatter)

      if frontmatter['keywords']&.any?
        yaml_front.sub!(/^keywords:\s*\n(?:- .+\n)+/) do
          "keywords: #{frontmatter['keywords'].to_json}\n"
        end
      end

      File.write(spec_path, content.sub(/^---\n.*?\n---\n/m, "#{yaml_front}---\n"))
    end

    def patch_owner_in_spec(spec_path, owner)
      content    = File.read(spec_path)
      yaml_match = content.match(/^---\n(.*?)\n---\n/m)
      return unless yaml_match

      begin
        frontmatter = YAML.safe_load(yaml_match[1], permitted_classes: SemanticSpecs::YAML_PERMITTED_CLASSES, aliases: true)
      rescue Psych::Exception
        return
      end

      return unless frontmatter.is_a?(Hash)
      return if frontmatter['owner'] == owner

      frontmatter['owner'] = owner
      yaml_front = YAML.dump(frontmatter)

      if frontmatter['keywords']&.any?
        yaml_front.sub!(/^keywords:\s*\n(?:- .+\n)+/) do
          "keywords: #{frontmatter['keywords'].to_json}\n"
        end
      end

      updated = content.sub(/^---\n.*?\n---\n/m, "#{yaml_front}---\n")
      File.write(spec_path, updated)
      puts "  Owner set: #{owner}"
    end

    def compress_paths(files)
      files
        .map { |f| f.split('/').first(PATH_DEPTH).join('/') }
        .uniq
        .sort
    end

    def extract_packs(files)
      packs = []
      files.each do |file|
        if file.match(%r{/packs/([^/]+)/})
          pack_name = Regexp.last_match(1)
          packs << pack_name if File.exist?(File.join(@root, 'packs', pack_name, 'package.yml'))
        end
      end
      packs.uniq.sort
    end

    def generate_spec_id(name)
      "ID-#{name.upcase.gsub(/[^A-Z0-9]/, '-')}"
    end
  end
end
