# frozen_string_literal: true

require "json"
require "fileutils"

module CapybaraAccessibilityAudit
  class IgnoreListMerger
    def self.merge(ignore_paths:, output_path:)
      new(ignore_paths: ignore_paths, output_path: output_path).merge
    end

    def self.merge_data(ignore_lists)
      new.merge_data(ignore_lists)
    end

    def initialize(ignore_paths: [], output_path: nil)
      @ignore_paths = Array(ignore_paths)
      @output_path = output_path
    end

    def merge
      validate_inputs!
      ignore_lists = load_ignore_lists
      merged = merge_data(ignore_lists)
      write_output(merged) if @output_path
      merged
    end

    def merge_data(ignore_lists)
      return empty_ignore_list if ignore_lists.empty?

      merged_violations = merge_ignored_violations(ignore_lists)
      latest_timestamp = ignore_lists.map { |il| il[:generated_at] }.compact.max || Time.now.iso8601

      {
        generated_at: latest_timestamp,
        description: "Baseline accessibility violations to be ignored. Remove entries as violations are fixed.",
        ignored_violations: merged_violations
      }
    end

    private

    def validate_inputs!
      raise ArgumentError, "No ignore list paths provided" if @ignore_paths.empty?

      @ignore_paths.each do |path|
        raise ArgumentError, "File not found: #{path}" unless File.exist?(path)
      end
    end

    def load_ignore_lists
      @ignore_paths.map do |path|
        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError => e
        raise JSON::ParserError, "Invalid JSON in #{path}: #{e.message}"
      end
    end

    def write_output(merged_data)
      FileUtils.mkdir_p(File.dirname(@output_path))
      File.write(@output_path, JSON.pretty_generate(merged_data))

      total_rules = merged_data[:ignored_violations].keys.count
      total_violations = merged_data[:ignored_violations].values.sum(&:count)

      puts "\n" + "=" * 80
      puts "IGNORE LISTS MERGED"
      puts "=" * 80
      puts "Output: #{@output_path}"
      puts "Source files: #{@ignore_paths.count}"
      puts "Total rules with ignored violations: #{total_rules}"
      puts "Total ignored violations: #{total_violations}"
      puts "=" * 80 + "\n"
    end

    def empty_ignore_list
      {
        generated_at: Time.now.iso8601,
        description: "Baseline accessibility violations to be ignored. Remove entries as violations are fixed.",
        ignored_violations: {}
      }
    end

    def merge_ignored_violations(ignore_lists)
      violations_by_rule = {}

      ignore_lists.each do |ignore_list|
        ignored_violations = ignore_list[:ignored_violations] || {}

        ignored_violations.each do |rule_id, entries|
          violations_by_rule[rule_id] ||= []

          entries.each do |entry|
            # Deduplicate by html + target combination
            unless violations_by_rule[rule_id].any? { |e|
              e[:html] == entry[:html] && e[:target] == entry[:target]
            }
              violations_by_rule[rule_id] << {
                html: entry[:html],
                target: entry[:target]
              }
            end
          end
        end
      end

      # Sort for consistent output
      sorted_violations = violations_by_rule.sort.to_h
      sorted_violations.each do |_rule_id, entries|
        entries.sort_by! { |e| e[:target].to_s }
      end

      sorted_violations
    end
  end
end
