# frozen_string_literal: true

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
      case mode_config
      when false # Backwards compatibility: accessibility_audit_enabled = false
        Disabled.new
      when true # Backwards compatibility: accessibility_audit_enabled = true
        Assert.new
      when :assert
        Assert.new
      when :stdout
        StdoutReporter.new
      when :baseline
        BaselineCollector.new
      when Hash
        if mode_config[:file]
          FileReporter.new(output_path: mode_config[:file])
        else
          raise ArgumentError, "Invalid report mode configuration: #{mode_config.inspect}"
        end
      else
        raise ArgumentError, "Invalid report mode: #{mode_config.inspect}. Expected false, true, :assert, :stdout, :baseline, or { file: 'path' }"
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
        # If ignore file exists, filter violations
        if File.exist?(ignore_file_path)
          require_relative "violation_ignore_list"
          ignore_list = ViolationIgnoreList.new(ignore_file_path)
          filtered_violations = ignore_list.filter_violations(audit.results.violations)

          # If all violations were filtered, don't fail the test
          return nil if filtered_violations.empty?

          # Build a custom failure message with only new violations
          build_failure_message(filtered_violations)
        else
          # No ignore file, use default behavior
          audit.failure_message
        end
      end

      private

      def build_failure_message(violations)
        message = ["Found new accessibility violations"]

        violations.each do |violation|
          message << "\n\n#{violation.help} (#{violation.id})"
          message << "  #{violation.helpUrl}"
          message << "  Affected elements (#{violation.nodes.count}):"
          violation.nodes.each do |node|
            message << "    #{node.target.join(", ")}"
          end
        end

        message.join("\n")
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
