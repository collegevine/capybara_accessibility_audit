# frozen_string_literal: true

require "json"
require "fileutils"
require "uri"
require_relative "violation_ignore_list"

module CapybaraAccessibilityAudit
  class Reporter
    DEFAULT_IGNORE_FILE_PATH = "capybara_accessibility_audit.ignore.json"
    IMPACT_PRIORITY = {
      "critical" => 4,
      "serious" => 3,
      "moderate" => 2,
      "minor" => 1
    }

    # Class-level current reporter for finalization (SimpleCov pattern)
    def self.current
      @current
    end

    def self.current=(reporter)
      @current = reporter
    end

    def self.finalize_current!
      current&.finalize!
      @current = nil
    end

    attr_reader :violations

    def initialize
      @violations = []
    end

    # Base class for reporters
    def enabled?
      true
    end

    def report?
      false
    end

    def assert?
      !report?
    end

    def handle_violations(audit:, url:)
      raise NotImplementedError
    end

    # Called at the end of the test suite to finalize reporting
    # Override in subclasses that need end-of-suite behavior
    def finalize!
      # Default: do nothing
    end

    # Factory method to create reporter from config
    # Supports backwards compatibility with accessibility_audit_enabled:
    #   false -> Disabled (backwards compatible with accessibility_audit_enabled = false)
    #   true -> Assert (backwards compatible with accessibility_audit_enabled = true)
    #   Reporter::Assert.new -> Assert mode
    #   Reporter::Assert.new(ignore_file_path: 'path') -> Assert mode with ignore file
    #   Reporter::Stdout.new -> Report to stdout
    #   Reporter::JSONFile.new(output_path: 'path') -> Report to JSON file
    #   Reporter::BaselineCollector.new -> Collect violations to default ignore file
    #   Reporter::BaselineCollector.new(output_path: 'path') -> Collect violations to custom path
    def self.from_config(reporter_config)
      # If already a Reporter instance, return it directly
      return reporter_config if reporter_config.is_a?(Reporter)

      case reporter_config
      when false # Backwards compatibility: accessibility_audit_enabled = false
        Disabled.new
      when true # Backwards compatibility: accessibility_audit_enabled = true
        Assert.new
      else
        raise ArgumentError, "Invalid reporter: #{reporter_config.inspect}. Expected true, false, or a Reporter instance"
      end
    end

    protected

    # Shared utility for collecting violations
    def add_violation(audit:, url:, timestamp: Time.now)
      @violations << {
        url: url,
        timestamp: timestamp.iso8601,
        violations: audit.results.violations.map { |v| violation_to_hash(v) },
        test_engine: audit.results.testEngine,
        test_environment: audit.results.testEnvironment
      }
    end

    # Formatting utilities
    def violation_to_hash(rule)
      {
        id: rule.id,
        impact: rule.impact,
        description: rule.description,
        help: rule.help,
        helpUrl: rule.helpUrl,
        tags: rule.tags,
        nodes: rule.nodes.map { |node| node_to_hash(node) }
      }
    end

    def node_to_hash(node)
      {
        html: node.html,
        target: node.target,
        failureSummary: node.failureSummary,
        impact: node.impact
      }
    end

    def total_violation_count
      violations.sum { |page_data| page_data[:violations].count }
    end

    def summary_data
      {
        summary: {
          total_violations: total_violation_count,
          num_pages_with_violations: violations.count,
          num_violations_by_impact: num_violations_by_impact,
          generated_at: Time.now.iso8601
        },
        violations_by_rule: group_violations_by_rule,
        violations_by_page: violations
      }
    end

    def num_violations_by_impact
      impact_counts = Hash.new(0)

      violations.each do |page_data|
        page_data[:violations].each do |violation|
          impact = violation[:impact].to_s
          impact_counts[impact] += violation[:nodes].count
        end
      end

      IMPACT_PRIORITY.keys.sort_by { |impact| -IMPACT_PRIORITY[impact] }.each_with_object({}) do |impact, result|
        result[impact] = impact_counts[impact]
      end
    end

    def group_violations_by_rule
      rule_counts = Hash.new(0)
      rule_details = {}

      violations.each do |page_data|
        page_data[:violations].each do |violation|
          rule_id = violation[:id]
          rule_counts[rule_id] += violation[:nodes].count
          rule_details[rule_id] ||= {
            impact: violation[:impact],
            description: violation[:description],
            help: violation[:help],
            helpUrl: violation[:helpUrl],
            tags: violation[:tags]&.sort || [],
            num_occurrences: 0,
            pages: []
          }
          rule_details[rule_id][:num_occurrences] += violation[:nodes].count
          rule_details[rule_id][:pages] << page_data[:url] unless rule_details[rule_id][:pages].include?(page_data[:url])
        end
      end

      rule_details.each do |_rule_id, data|
        data[:pages].sort!
      end

      rule_details.sort_by do |_id, data|
        [
          -IMPACT_PRIORITY.fetch(data[:impact].to_s, 0),
          -data[:num_occurrences]
        ]
      end.to_h
    end

    # Disabled mode - audits don't run at all
    # Used for backwards compatibility when accessibility_audit_enabled = false
    class Disabled < Reporter
      def enabled?
        false
      end

      def handle_violations(audit:, url:)
        raise "Impossible state: handle_violations called on Disabled mode. Audits should not run when disabled."
      end
    end

    # Assert mode - fails tests on violations (default behavior)
    # If capybara_accessibility_audit.ignore.json exists, filters out ignored violations
    class Assert < Reporter
      attr_accessor :ignore_file_path

      def initialize(ignore_file_path: DEFAULT_IGNORE_FILE_PATH, custom_help_message: nil)
        # Don't call super - no @violations needed for assert mode
        @ignore_file_path = ignore_file_path
        @custom_help_message = custom_help_message
      end

      def assert?
        true
      end

      def handle_violations(audit:, url:)
        # Return failure message if no ignore file exists
        return audit.failure_message unless File.exist?(ignore_file_path)

        ignore_list = ViolationIgnoreList.new(ignore_file_path)
        filtered_violations = ignore_list.filter_violations(audit.results.violations)

        return nil if filtered_violations.empty?

        build_failure_message(
          violations: filtered_violations,
          url: url
        )
      end

      private

      def build_failure_message(violations:, url:)
        message = ["Found new accessibility violations:"]
        message << "\nPath: #{strip_url_prefix(url)}"

        violations.each do |violation|
          message << "\n#{violation.id}: #{violation.help} (#{violation.impact})"
          message << "#{violation.helpUrl}"

          message << "\nAffected nodes (#{violation.nodes.count}):\n"
          violation.nodes.each do |node|
            message << "  HTML: #{node.html}"
            message << "  Selector: #{node.target.join(" ")}"
            message << "\n  #{node.failureSummary.to_s.split("\n  ").join("\n  - ")}"
          end

          message << "\nIMPORTANT: If these are false positives, ignore them by adding this to"
          message << "the ignore file:"
          message << "\n  #{@custom_help_message.split("\n").join("\n  ")}" if @custom_help_message && @custom_help_message != ''
          message << "\n  File: #{@ignore_file_path}"
          message << "  JSON path: `$.ignored_violations.#{violation.id}`\n"
          ignore_directives = []
          violation.nodes.each do |node|
            ignore_directives << JSON.pretty_generate(
              {
                "html" => node.html,
                "target" => node.target
              }
            ).gsub(/^/, " " * 4)
          end
          message << ignore_directives.join(",\n")
        end

        message.join("\n")
      end

      def strip_url_prefix(url)
        uri = URI(url)
        uri.request_uri + (uri.fragment ? "##{uri.fragment}" : "")
      end
    end

    # Stdout reporter - collects and outputs to console
    class Stdout < Reporter
      def report?
        true
      end

      def handle_violations(audit:, url:)
        add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        write_to_stdout
      end

      private

      def write_to_stdout
        puts "\n" + "=" * 80
        puts "ACCESSIBILITY AUDIT REPORT"
        puts "=" * 80
        puts "Total violations found: #{total_violation_count}"
        puts "Pages with violations: #{violations.count}"
        puts "=" * 80

        violations.each_with_index do |page_data, idx|
          puts "\n#{idx + 1}. URL: #{page_data[:url]}"
          puts "   Time: #{page_data[:timestamp]}"
          puts "   Violations: #{page_data[:violations].count}"

          page_data[:violations].each do |violation|
            puts "\n   - [#{violation[:impact].upcase}] #{violation[:id]}"
            puts "     #{violation[:help]}"
            puts "     #{violation[:helpUrl]}"
            puts "     Affected elements: #{violation[:nodes].count}"
            puts "     Tags: #{violation[:tags].join(", ")}"
          end
          puts "   " + "-" * 76
        end

        puts "=" * 80 + "\n"
      end
    end

    # JSON file reporter - collects and outputs to JSON
    class JSONFile < Reporter
      attr_reader :file_path

      def initialize(output_path:)
        super() # Initialize @violations = []
        @file_path = output_path
      end

      def report?
        true
      end

      def handle_violations(audit:, url:)
        add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        write_to_json(file_path)
      end

      private

      def write_to_json(file_path)
        FileUtils.mkdir_p(::File.dirname(file_path))
        ::File.write(file_path, JSON.pretty_generate(summary_data))
        puts "\n======> Accessibility audit report written to: #{file_path}"
      end
    end

    # Baseline reporter - collects and generates ignore file
    class BaselineCollector < Reporter
      attr_accessor :output_path

      def initialize(output_path: DEFAULT_IGNORE_FILE_PATH)
        super() # Initialize @violations = []
        @output_path = output_path
      end

      def report?
        true
      end

      def handle_violations(audit:, url:)
        add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        ViolationIgnoreList.generate_baseline(
          violations: @violations,
          output_path: output_path
        )
      end
    end
  end
end
