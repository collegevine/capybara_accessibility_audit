# frozen_string_literal: true

require "json"

module CapybaraAccessibilityAudit
  # Manages a list of ignored accessibility violations for gradual adoption
  #
  # The ignore list allows teams to introduce accessibility auditing into existing
  # codebases with many violations. Violations can be ignored by:
  #
  # - Rule ID + HTML snippet + target selector (ignores specific element on specific page)
  class ViolationIgnoreList
    attr_reader :file_path

    def initialize(file_path)
      @file_path = file_path
      @ignores = load_ignores
    end

    def ignored?(rule_id:, html:, target:)

      rule_ignores = @ignores[rule_id.to_s]
      return false unless rule_ignores

      return true if rule_ignores.empty?

      rule_ignores.any? do |ignore_entry|
        matches_html?(ignore_entry, html) &&
        matches_target?(ignore_entry, target)
      end
    end

    # Filter violations from an audit, returning only non-ignored violations
    def filter_violations(violations)
      violations.map do |violation|
        filtered_nodes = violation.nodes.reject do |node|
          ignored?(
            rule_id: violation.id,
            html: node.html,
            target: node.target
          )
        end

        next if filtered_nodes.empty?

        OpenStruct.new(
          id: violation.id,
          impact: violation.impact,
          description: violation.description,
          help: violation.help,
          helpUrl: violation.helpUrl,
          tags: violation.tags,
          nodes: filtered_nodes
        )
      end.compact
    end

    # Generate a baseline ignore file from audit results
    def self.generate_baseline(violations:, output_path:)
      ignores = {}

      violations.each do |page_data|
        page_data[:violations].each do |violation|
          rule_id = violation[:id]
          ignores[rule_id] ||= []

          violation[:nodes].each do |node|
            # Create entry with HTML and target
            html = node[:html]
            target = node[:target]

            # Add if not already present (matching by HTML and target)
            unless ignores[rule_id].any? { |e| e[:html] == html && e[:target] == target }
              ignores[rule_id] << {html: html, target: target}
            end
          end
        end
      end

      # Sort for consistent output
      sorted_ignores = ignores.sort.to_h
      sorted_ignores.each do |_rule_id, entries|
        entries.sort_by! { |e| e[:target].to_s }
      end

      data = {
        generated_at: Time.now.iso8601,
        description: "Baseline accessibility violations to be ignored. Remove entries as violations are fixed.",
        ignored_violations: sorted_ignores
      }

      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, JSON.pretty_generate(data))

      puts "\n" + "=" * 80
      puts "BASELINE IGNORE FILE GENERATED"
      puts "=" * 80
      puts "File: #{output_path}"
      puts "Total rules with violations: #{sorted_ignores.keys.count}"
      puts "Total ignored violations: #{sorted_ignores.values.sum(&:count)}"
      puts "\nTo use this baseline:"
      puts "  self.accessibility_audit_report_mode = CapybaraAccessibilityAudit::ReportMode::Assert.new(ignore_file_path: '#{output_path}')"
      puts "\nAs you fix violations, remove the corresponding entries from the ignore file."
      puts "=" * 80 + "\n"
    end

    private

    def load_ignores
      return {} unless File.exist?(@file_path)

      data = JSON.parse(File.read(@file_path))
      data["ignored_violations"] || {}
    rescue JSON::ParserError => e
      warn "Warning: Could not parse ignore file #{@file_path}: #{e.message}"
      {}
    end

    def matches_html?(ignore_entry, html)
      return true unless ignore_entry["html"]

      ignore_entry["html"] == html
    end

    def matches_target?(ignore_entry, target)
      return true unless ignore_entry["target"]

      ignore_entry["target"] == target
    end
  end
end
