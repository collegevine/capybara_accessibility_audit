# frozen_string_literal: true

require "uri"
require_relative "violation_ignore_list"

module CapybaraAccessibilityAudit
  class ReportMode
    IGNORE_FILE = "capybara_accessibility_audit.ignore.json"

    # Base class for report modes
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

    # Factory method to create mode from config
    # Supports backwards compatibility with accessibility_audit_enabled:
    #   false -> Disabled (backwards compatible with accessibility_audit_enabled = false)
    #   true -> Assert (backwards compatible with accessibility_audit_enabled = true)
    #   ReportMode::Assert.new -> Assert mode
    #   ReportMode::Assert.new(ignore_file_path: 'path') -> Assert mode with ignore file
    #   ReportMode::StdoutReporter.new -> Report to stdout
    #   ReportMode::FileReporter.new(output_path: 'path') -> Report to JSON file
    #   ReportMode::BaselineCollector.new -> Collect violations to default ignore file
    #   ReportMode::BaselineCollector.new(output_path: 'path') -> Collect violations to custom path
    def self.from_config(mode_config)
      # If already a ReportMode instance, return it directly
      return mode_config if mode_config.is_a?(ReportMode)

      case mode_config
      when false # Backwards compatibility: accessibility_audit_enabled = false
        Disabled.new
      when true # Backwards compatibility: accessibility_audit_enabled = true
        Assert.new
      else
        raise ArgumentError, "Invalid report mode: #{mode_config.inspect}. Expected true, false, or a ReportMode instance"
      end
    end

    # Disabled mode - audits don't run at all
    # Used for backwards compatibility when accessibility_audit_enabled = false
    class Disabled < ReportMode
      def enabled?
        false
      end

      def handle_violations(audit:, url:)
        raise "Impossible state: handle_violations called on Disabled mode. Audits should not run when disabled."
      end
    end

    # Assert mode - fails tests on violations (default behavior)
    # If capybara_accessibility_audit.ignore.json exists, filters out ignored violations
    class Assert < ReportMode
      attr_accessor :ignore_file_path

      def initialize(ignore_file_path: IGNORE_FILE)
        @ignore_file_path = ignore_file_path
      end

      def assert?
        true
      end

      def handle_violations(audit:, url:)
        # Revisit by checking file once
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
        message = ["Found new accessibility violations"]
        message << "\nPath: #{strip_url_prefix(url)}"

        violations.each do |violation|
          message << "\nRule ID: #{violation.id}"
          message << "#{"-" * 80}"
          message << "#{violation.help}"
          message << "#{violation.helpUrl}"

          message << "\nAffected elements (#{violation.nodes.count}):\n"
          violation.nodes.each do |node|
            message << "  #{node.target.join(" ")}"
          end

          message << "\nIMPORTANT: If these are false positives, ignore them by"
          message << "adding this to the ignore file and posting in the"
          message<< "#i-wcag-accessibility Slack channel:"
          message << "File: #{@ignore_file_path}"
          message << "JSON path: `$.ignored_violations.#{violation.id}`\n"
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

    # Stdout mode - logs violations to stdout, doesn't fail tests
    class StdoutReporter < ReportMode
      def report?
        true
      end

      def handle_violations(audit:, url:)
        Reporter.add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        Reporter.report_to_stdout!
      end
    end

    # File mode - logs violations to JSON file, doesn't fail tests
    class FileReporter < ReportMode
      attr_reader :file_path

      def initialize(output_path:)
        @file_path = output_path
        Reporter.report_file_path = output_path
      end

      def report?
        true
      end

      def handle_violations(audit:, url:)
        Reporter.add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        Reporter.report_to_json!(file_path)
      end
    end

    # Baseline mode - collects violations and generates ignore file
    # Use this to create the initial capybara_accessibility_audit.ignore.json
    class BaselineCollector < ReportMode
      attr_accessor :output_path

      def initialize(output_path: IGNORE_FILE)
        @output_path = output_path
      end

      def report?
        true
      end

      def handle_violations(audit:, url:)
        Reporter.add_violation(audit: audit, url: url)
        nil # Don't fail the test
      end

      def finalize!
        require_relative "violation_ignore_list"
        ViolationIgnoreList.generate_baseline(
          violations: Reporter.violations,
          output_path: output_path
        )
      end
    end
  end
end
